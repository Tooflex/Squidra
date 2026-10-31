import Foundation
import PostgresNIO
import SquidraWorld

extension PostgresLocationProjection: WorldChangesQuerying {
    public func changes(_ query: WorldChangesQuery, cursor: WorldChangesCursor? = nil, limit: Int = 32,
                        deadline: ContinuousClock.Instant) async throws -> WorldChangesPage {
        guard query.actorID == actorID else { throw WorldChangesError.notFound }
        guard (1...128).contains(limit),cursor.map({ $0.query == query }) ?? true else { throw WorldChangesError.invalidCursor }
        do {
            return try await transaction(deadline:deadline,readOnly:true) { connection in
                let metadata = try await BoundedPostgresQuery.rows(connection,"""
                    SELECT (SELECT version FROM projection_versions WHERE actor_id=\(actorID) AND projection_name='world.locations'),
                        (SELECT coalesce(last_sequence,0) FROM projection_versions WHERE actor_id=\(actorID) AND projection_name='world.locations'),
                        (SELECT coalesce(max(sequence),0)::bigint FROM world_events WHERE actor_id=\(actorID)),
                        (\(query.subjectID == nil) OR EXISTS(SELECT 1 FROM world_entities WHERE actor_id=\(actorID) AND id=\(query.subjectID))),
                        (\(query.locationID == nil) OR EXISTS(SELECT 1 FROM world_entities WHERE actor_id=\(actorID) AND id=\(query.locationID)))
                    """)
                guard let row = metadata.first else { throw WorldChangesError.corruptRecord }
                let (version,last,maximum,subjectExists,locationExists) = try row.decode((Int?,Int64?,Int64,Bool,Bool).self)
                guard subjectExists,locationExists else { throw WorldChangesError.notFound }
                guard version == nil || version == 1 else { throw WorldChangesError.unsupportedSchema }
                let through = cursor?.throughSequence ?? (last ?? 0),available = cursor?.availableThroughSequence ?? maximum
                guard through <= (last ?? 0),available <= maximum,available >= through else { throw WorldChangesError.invalidCursor }
                let bindings = ChangesSQL.bindings(query,cursor:cursor,through:through,limit:limit,current:nil)
                let rows = try await BoundedPostgresQuery.rows(connection,PostgresQuery(unsafeSQL:ChangesSQL.candidates,binds:bindings))
                var changes: [WorldChange] = []
                for row in rows.prefix(limit) {
                    struct Metadata: Decodable { let subject_id: UUID,event_type: String }
                    let text = try row.decode(String.self)
                    guard text.utf8.count <= 8_192 else { throw WorldChangesError.corruptRecord }
                    let fields = try JSONDecoder().decode(Metadata.self,from:Data(text.utf8))
                    let current = try decodeFact(row,subjectID:fields.subject_id)
                    let binds = ChangesSQL.bindings(query,cursor:cursor,through:through,limit:limit,current:current.id)
                    let previousRows = try await BoundedPostgresQuery.rows(connection,PostgresQuery(unsafeSQL:ChangesSQL.previous,binds:binds))
                    guard previousRows.count <= 128 else { throw WorldChangesError.resultLimitExceeded }
                    let previous = try previousRows.map { try decodeFact($0,subjectID:fields.subject_id) }
                    let counts = try await BoundedPostgresQuery.rows(connection,PostgresQuery(unsafeSQL:ChangesSQL.conflicts,binds:binds))
                    guard let count = counts.first else { throw WorldChangesError.corruptRecord }
                    let conflicting = try count.decode(Int.self) > 1
                    changes.append(try WorldChange(current:current,previous:previous,isCorrection:fields.event_type == "world.location_corrected",
                        conflictingCurrent:conflicting,projectionBehind:through < available))
                }
                let next: WorldChangesCursor?
                if rows.count > limit,let last = changes.last {
                    next = try WorldChangesCursor(query:query,throughSequence:through,availableThroughSequence:available,
                        afterValidMicroseconds:last.current.valid.fromMicroseconds,afterFactID:last.id)
                } else { next = nil }
                return WorldChangesPage(changes:changes,next:next,throughSequence:through,availableThroughSequence:available)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as WorldChangesError { throw error }
        catch let error as WorldProjectionError {
            switch error {
            case .notFound: throw WorldChangesError.notFound
            case .unsupportedEvent,.versionConflict: throw WorldChangesError.unsupportedSchema
            case .resultLimitExceeded: throw WorldChangesError.resultLimitExceeded
            case .invalidFact,.corruptRecord,.nonMonotonicKnowledgeTime,.outOfOrder: throw WorldChangesError.corruptRecord
            case .unavailable: throw WorldChangesError.unavailable
            }
        } catch { throw WorldChangesError.unavailable }
    }
}

/// SQL fragments contain only private fixed identifiers/grammar. Every actor,
/// time, filter, cursor and limit is bound through the driver's typed bindings.
private enum ChangesSQL {
    static let parameters = """
        WITH q AS(SELECT $1::uuid AS actor,$2::bigint AS known_us,$3::bigint AS through_seq,$4::bigint AS start_us,$5::bigint AS end_us,
            $6::uuid AS subject,$7::uuid AS location,$8::bigint AS after_us,$9::uuid AS after_id,$10::integer AS lim,$11::boolean AS initial,$12::uuid AS current_id)
        """
    static func bindings(_ query: WorldChangesQuery, cursor: WorldChangesCursor?, through: Int64, limit: Int, current: UUID?) -> PostgresBindings {
        var values = PostgresBindings()
        values.append(query.actorID);values.append(query.knownMicroseconds);values.append(through)
        values.append(query.window.fromMicroseconds);values.append(query.window.toMicroseconds!)
        values.append(query.subjectID);values.append(query.locationID);values.append(cursor?.afterValidMicroseconds ?? query.window.fromMicroseconds)
        values.append(cursor?.afterFactID ?? UUID(uuidString:"00000000-0000-0000-0000-000000000000")!)
        values.append(limit+1);values.append(cursor == nil);values.append(current)
        return values
    }
    private static func timestamp(_ value: String) -> String {
        "(to_timestamp((\(value)/1000000)::double precision)+(\(value)%1000000)*interval '1 microsecond')"
    }
    private static func relations(_ f: String,_ e: String,_ closed: String) -> String {
        """
        spatial_facts \(f) JOIN world_events \(e) ON \(e).actor_id=\(f).actor_id AND \(e).event_id=\(f).provenance_event_id
        LEFT JOIN LATERAL(SELECT x.sequence FROM world_events x WHERE x.actor_id=\(f).actor_id AND x.causation_id=\(f).provenance_event_id
            AND x.event_type='world.location_corrected' AND x.payload_version=1 AND x.payload->>'journalSchemaVersion'='1'
            AND x.recorded_at=\(f).tx_to ORDER BY x.sequence LIMIT 1) \(closed) ON \(f).tx_to IS NOT NULL
        """
    }
    private static func visible(_ f: String,_ e: String,_ closed: String) -> String {
        """
        \(e).sequence<=q.through_seq AND \(f).tx_from<=\(timestamp("q.known_us"))
        AND (\(f).tx_to IS NULL OR \(timestamp("q.known_us"))<\(f).tx_to OR \(closed).sequence>q.through_seq OR \(closed).sequence IS NULL)
        """
    }
    private static func fields(_ f: String,_ e: String,_ closed: String) -> String {
        """
        \(f).id,\(f).actor_id,\(f).subject_id,\(f).object_id,\(f).frame_id,
        floor(extract(epoch FROM \(f).valid_from)*1000000)::bigint AS valid_from_us,
        floor(extract(epoch FROM \(f).valid_to)*1000000)::bigint AS valid_to_us,
        floor(extract(epoch FROM \(f).tx_from)*1000000)::bigint AS tx_from_us,
        CASE WHEN \(closed).sequence>q.through_seq THEN NULL ELSE floor(extract(epoch FROM \(f).tx_to)*1000000)::bigint END AS tx_to_us,
        \(f).confidence,\(f).provenance_event_id,\(e).source_id,\(e).payload_version,\(e).payload->>'journalSchemaVersion' AS envelope_version,
        \(e).payload->>'timeZone' AS source_zone,\(e).payload->'data'->>'basis' AS basis,\(e).event_type,
        floor(extract(epoch FROM \(e).occurred_at)*1000000)::bigint AS occurred_us,
        floor(extract(epoch FROM \(e).observed_at)*1000000)::bigint AS observed_us,
        floor(extract(epoch FROM \(e).recorded_at)*1000000)::bigint AS recorded_us,
        (\(f).id=\(e).event_id AND \(f).subject_id=(\(e).payload->'data'->>'subjectId')::uuid AND \(f).object_id=(\(e).payload->'data'->>'locationId')::uuid
            AND \(f).frame_id=(\(e).payload->'data'->>'frameId')::uuid AND \(f).confidence=\(e).confidence AND \(f).tx_from=\(e).recorded_at
            AND floor(extract(epoch FROM \(f).valid_from)*1000000)::bigint=(\(e).payload->'data'->>'validFromMicroseconds')::numeric::bigint
            AND floor(extract(epoch FROM \(f).valid_to)*1000000)::bigint IS NOT DISTINCT FROM (\(e).payload->'data'->>'validToMicroseconds')::numeric::bigint
            AND (\(f).tx_to IS NULL OR \(closed).sequence IS NOT NULL)) AS source_matches
        """
    }
    private static var support: String {
        """
        p.actor_id=f.actor_id AND p.subject_id=f.subject_id AND p.frame_id=f.frame_id AND p.predicate='located_at' AND p.id<>f.id
        AND pe.sequence<=q.through_seq AND (
            (e.event_type='world.location_corrected' AND p.provenance_event_id=e.causation_id AND p.tx_to=e.recorded_at AND pe.sequence<e.sequence)
            OR (e.event_type='world.location_asserted' AND p.valid_to=f.valid_from AND \(visible("p","pe","close_p"))))
        """
    }
    static var candidates: String {
        parameters+"\n"+"""
        SELECT row_to_json(r)::text FROM(SELECT \(fields("f","e","close_f"))
        FROM \(relations("f","e","close_f")) CROSS JOIN q
        WHERE f.actor_id=q.actor AND f.predicate='located_at' AND \(visible("f","e","close_f"))
            AND f.valid_from>=\(timestamp("q.start_us")) AND f.valid_from<\(timestamp("q.end_us"))
            AND (q.subject IS NULL OR f.subject_id=q.subject)
            AND (q.location IS NULL OR f.object_id=q.location OR EXISTS(SELECT 1 FROM \(relations("p","pe","close_p")) WHERE \(support) AND p.object_id=q.location))
            AND (q.initial OR (f.valid_from,f.id)>(\(timestamp("q.after_us")),q.after_id))
        ORDER BY f.valid_from,f.id LIMIT(SELECT lim FROM q)) AS r
        """
    }
    static var previous: String {
        parameters+"\n"+"""
        SELECT row_to_json(r)::text FROM(SELECT \(fields("p","pe","close_p"))
        FROM \(relations("p","pe","close_p")) CROSS JOIN spatial_facts f JOIN world_events e ON e.actor_id=f.actor_id AND e.event_id=f.provenance_event_id CROSS JOIN q
        WHERE f.actor_id=q.actor AND f.id=q.current_id AND \(support)
        ORDER BY p.object_id,p.provenance_event_id LIMIT 129) AS r
        """
    }
    static var conflicts: String {
        parameters+"\n"+"""
        SELECT count(*)::integer FROM(SELECT DISTINCT p.object_id FROM \(relations("p","pe","close_p")) CROSS JOIN spatial_facts f CROSS JOIN q
        WHERE f.actor_id=q.actor AND f.id=q.current_id AND p.actor_id=f.actor_id AND p.subject_id=f.subject_id AND p.frame_id=f.frame_id
            AND p.predicate='located_at' AND \(visible("p","pe","close_p")) AND p.valid_from<=f.valid_from AND (p.valid_to IS NULL OR f.valid_from<p.valid_to)
        LIMIT 2) AS places
        """
    }
}
