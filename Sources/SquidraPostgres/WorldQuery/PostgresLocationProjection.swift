import Foundation
import PostgresNIO
import SquidraDomain
import SquidraWorld

/// One actor's durable located_at materialization. Other relation/geometry
/// semantics are separate profiles; their assertions are not inferred here.
public struct PostgresLocationProjection: WorldProjector, WorldStateQuery {
    public let actorID: UUID
    private let client: PostgresClient
    public init(actorID: UUID, client: PostgresClient) { self.actorID = actorID;self.client = client }
    public func apply(_ event: JournalEvent) async throws {
        try await apply(event,deadline:.now.advanced(by:.seconds(4)))
    }
    public func apply(_ event: JournalEvent, deadline: ContinuousClock.Instant) async throws {
        guard event.draft.actorID == actorID else { throw WorldProjectionError.notFound }
        try await transaction(deadline:deadline) { connection in
            _ = try await BoundedPostgresQuery.rows(connection,"SELECT pg_advisory_xact_lock(hashtextextended(\(actorID.uuidString.lowercased()),1936818035))")
            let stored: JournalEvent
            do { stored = try await PostgresWorldRepository(client:client).select(connection,actorID:actorID,id:event.draft.id) }
            catch WorldJournalError.unsupportedEvent { throw WorldProjectionError.unsupportedEvent }
            catch WorldJournalError.notFound { throw WorldProjectionError.notFound }
            catch { throw WorldProjectionError.corruptRecord }
            guard stored.sequence == event.sequence,stored.streamVersion == event.streamVersion else { throw WorldProjectionError.invalidFact }
            let rows = try await BoundedPostgresQuery.rows(connection,"SELECT version,last_sequence FROM projection_versions WHERE actor_id=\(actorID) AND projection_name='world.locations' FOR UPDATE")
            var last: Int64 = 0
            if let row = rows.first {
                let (version,sequence) = try row.decode((Int,Int64?).self)
                guard version == 1 else { throw WorldProjectionError.versionConflict };last = sequence ?? 0
            }
            if stored.sequence <= last { return }
            let following = try await BoundedPostgresQuery.rows(connection,"SELECT min(sequence) FROM world_events WHERE actor_id=\(actorID) AND sequence>\(last)")
            guard let row = following.first,try row.decode(Int64?.self) == stored.sequence else { throw WorldProjectionError.outOfOrder }
            if stored.draft.type.hasPrefix("world.location_") {
                let change = try LocationFactChange.decode(stored.draft)
                if let corrected = change.correctsEventID {
                    let previous = try await BoundedPostgresQuery.rows(connection,"""
                        SELECT id,subject_id,object_id,frame_id,floor(extract(epoch FROM tx_from)*1000000)::bigint
                        FROM spatial_facts WHERE actor_id=\(actorID) AND predicate='located_at'
                            AND provenance_event_id=\(corrected) AND tx_to IS NULL FOR UPDATE
                        """)
                    guard previous.count == 1,let row = previous.first else { throw WorldProjectionError.notFound }
                    let (id,subject,object,frame,known) = try row.decode((UUID,UUID,UUID,UUID,Int64).self)
                    guard subject == change.subjectID,frame == change.frameID,stored.draft.entityIDs.contains(object) else { throw WorldProjectionError.invalidFact }
                    guard stored.recordedMicroseconds > known else { throw WorldProjectionError.nonMonotonicKnowledgeTime }
                    let now = stored.recordedMicroseconds
                    let updated = try await BoundedPostgresQuery.rows(connection,"""
                        UPDATE spatial_facts SET tx_to=to_timestamp(\(Double(now/1_000_000)))+\(now%1_000_000)*interval '1 microsecond'
                        WHERE actor_id=\(actorID) AND id=\(id) AND tx_to IS NULL RETURNING id
                        """)
                    guard updated.count == 1 else { throw WorldProjectionError.versionConflict }
                }
                let from = change.valid.fromMicroseconds,toSeconds = change.valid.toMicroseconds.map { Double($0/1_000_000) },toFraction = change.valid.toMicroseconds.map { $0%1_000_000 }
                let known = stored.recordedMicroseconds
                _ = try await BoundedPostgresQuery.rows(connection,"""
                    INSERT INTO spatial_facts(id,actor_id,subject_id,predicate,object_id,frame_id,valid_from,valid_to,tx_from,confidence,provenance_event_id)
                    VALUES(\(stored.draft.id),\(actorID),\(change.subjectID),'located_at',\(change.locationID),\(change.frameID),
                        to_timestamp(\(Double(from/1_000_000)))+\(from%1_000_000)*interval '1 microsecond',
                        to_timestamp(\(toSeconds))+\(toFraction)*interval '1 microsecond',
                        to_timestamp(\(Double(known/1_000_000)))+\(known%1_000_000)*interval '1 microsecond',\(stored.draft.confidence.value),\(stored.draft.id))
                    """)
            }
            let checkpoint = try await BoundedPostgresQuery.rows(connection,"""
                INSERT INTO projection_versions(actor_id,projection_name,version,last_sequence) VALUES(\(actorID),'world.locations',1,\(stored.sequence))
                ON CONFLICT(actor_id,projection_name) DO UPDATE SET last_sequence=EXCLUDED.last_sequence,updated_at=clock_timestamp()
                    WHERE projection_versions.version=1 RETURNING version
                """)
            guard checkpoint.count == 1 else { throw WorldProjectionError.versionConflict }
        }
    }
    /// Checkpoint metadata describes the durable SQL materialization; it is not
    /// an export/backup of all rows. Rebuild still replays the authoritative journal.
    public func checkpoint() async throws -> ProjectionCheckpoint {
        try await transaction(deadline:.now.advanced(by:.seconds(4)),readOnly:true) { connection in
            let rows = try await BoundedPostgresQuery.rows(connection,"""
                SELECT (SELECT version FROM projection_versions WHERE actor_id=\(actorID) AND projection_name='world.locations'),
                    (SELECT last_sequence FROM projection_versions WHERE actor_id=\(actorID) AND projection_name='world.locations'),
                    (SELECT count(*)::bigint FROM spatial_facts WHERE actor_id=\(actorID) AND predicate='located_at'),
                    (SELECT count(*)::bigint FROM spatial_facts WHERE actor_id=\(actorID) AND predicate='located_at' AND tx_to IS NULL)
                """)
            guard let row = rows.first else { throw WorldProjectionError.corruptRecord }
            let (version,last,total,active) = try row.decode((Int?,Int64?,Int64,Int64).self)
            guard version == nil || version == 1,version != nil || total == 0 else { throw WorldProjectionError.versionConflict }
            let data = try JSONSerialization.data(withJSONObject:["schemaVersion":"1","projectionVersion":1,"actorId":actorID.uuidString.lowercased(),
                "lastSequence":last.map { NSNumber(value:$0) } ?? NSNull(),"factRows":total,"activeRows":active],options:[.sortedKeys])
            return try ProjectionCheckpoint(projectionVersion:1,lastSequence:last,state:JSONDocument(data))
        }
    }
    public func state(actorID requestedActor: UUID, subjectID: UUID, validAt: UTCInstant, knownAt: UTCInstant,
                      deadline: ContinuousClock.Instant) async throws -> WorldStateSnapshot {
        guard requestedActor == actorID else { throw WorldProjectionError.notFound }
        let times = try JournalTimes(occurredAt:knownAt,observedAt:validAt,timeZone:IANATimeZone(identifier:"Etc/UTC"))
        let valid = times.observedMicroseconds,known = times.occurredMicroseconds!
        return try await transaction(deadline:deadline,readOnly:true) { connection in
            let metadata = try await BoundedPostgresQuery.rows(connection,"""
                SELECT EXISTS(SELECT 1 FROM world_entities WHERE actor_id=\(actorID) AND id=\(subjectID)),
                    (SELECT version FROM projection_versions WHERE actor_id=\(actorID) AND projection_name='world.locations'),
                    (SELECT last_sequence FROM projection_versions WHERE actor_id=\(actorID) AND projection_name='world.locations'),
                    (SELECT coalesce(max(sequence),0)::bigint FROM world_events WHERE actor_id=\(actorID))
                """)
            guard let row = metadata.first else { throw WorldProjectionError.corruptRecord }
            let (exists,version,last,maximum) = try row.decode((Bool,Int?,Int64?,Int64).self)
            guard exists else { throw WorldProjectionError.notFound }
            guard version == nil || version == 1 else { throw WorldProjectionError.versionConflict }
            let rows = try await BoundedPostgresQuery.rows(connection,"""
                SELECT row_to_json(r)::text FROM (SELECT f.id,f.actor_id,f.subject_id,f.object_id,f.frame_id,
                    floor(extract(epoch FROM f.valid_from)*1000000)::bigint AS valid_from_us,
                    floor(extract(epoch FROM f.valid_to)*1000000)::bigint AS valid_to_us,
                    floor(extract(epoch FROM f.tx_from)*1000000)::bigint AS tx_from_us,
                    floor(extract(epoch FROM f.tx_to)*1000000)::bigint AS tx_to_us,f.confidence,f.provenance_event_id,
                    e.source_id,e.payload_version,e.payload->>'journalSchemaVersion' AS envelope_version,e.payload->>'timeZone' AS source_zone,
                    e.payload->'data'->>'basis' AS basis,floor(extract(epoch FROM e.occurred_at)*1000000)::bigint AS occurred_us,
                    floor(extract(epoch FROM e.observed_at)*1000000)::bigint AS observed_us,
                    floor(extract(epoch FROM e.recorded_at)*1000000)::bigint AS recorded_us,
                    (f.subject_id=(e.payload->'data'->>'subjectId')::uuid AND f.object_id=(e.payload->'data'->>'locationId')::uuid
                        AND f.frame_id=(e.payload->'data'->>'frameId')::uuid AND f.confidence=e.confidence AND f.tx_from=e.recorded_at
                        AND floor(extract(epoch FROM f.valid_from)*1000000)::bigint=(e.payload->'data'->>'validFromMicroseconds')::numeric::bigint
                        AND floor(extract(epoch FROM f.valid_to)*1000000)::bigint IS NOT DISTINCT FROM (e.payload->'data'->>'validToMicroseconds')::numeric::bigint) AS source_matches
                FROM spatial_facts f JOIN world_events e ON e.actor_id=f.actor_id AND e.event_id=f.provenance_event_id
                WHERE f.actor_id=\(actorID) AND f.subject_id=\(subjectID) AND f.predicate='located_at'
                    AND f.valid_from<=to_timestamp(\(Double(valid/1_000_000)))+\(valid%1_000_000)*interval '1 microsecond'
                    AND (f.valid_to IS NULL OR to_timestamp(\(Double(valid/1_000_000)))+\(valid%1_000_000)*interval '1 microsecond'<f.valid_to)
                    AND f.tx_from<=to_timestamp(\(Double(known/1_000_000)))+\(known%1_000_000)*interval '1 microsecond'
                    AND (f.tx_to IS NULL OR to_timestamp(\(Double(known/1_000_000)))+\(known%1_000_000)*interval '1 microsecond'<f.tx_to)
                ORDER BY f.frame_id,f.object_id,f.provenance_event_id LIMIT 129) AS r
                """)
            guard rows.count <= 128 else { throw WorldProjectionError.resultLimitExceeded }
            let facts = try rows.map { try decodeFact($0,subjectID:subjectID) }
            return WorldStateSnapshot(actorID:actorID,subjectID:subjectID,validAt:times.observedAt,knownAt:times.occurredAt!,facts:facts,
                projectedThroughSequence:last ?? 0,availableThroughSequence:maximum)
        }
    }
    private struct FactRow: Decodable {
        let id: UUID,actor_id: UUID,subject_id: UUID,object_id: UUID,frame_id: UUID,provenance_event_id: UUID
        let valid_from_us: Int64,valid_to_us: Int64?,tx_from_us: Int64,tx_to_us: Int64?,confidence: Double
        let source_id: String,payload_version: Int,envelope_version: String?,source_zone: String?,basis: LocationBasis?
        let occurred_us: Int64?,observed_us: Int64,recorded_us: Int64
        let source_matches: Bool?
    }
    private func decodeFact(_ row: PostgresRow, subjectID: UUID) throws -> WorldLocationFact {
        do {
            let text = try row.decode(String.self)
            guard text.utf8.count <= 8_192 else { throw WorldProjectionError.corruptRecord }
            let value = try JSONDecoder().decode(FactRow.self,from:Data(text.utf8))
            guard value.actor_id == actorID,value.subject_id == subjectID,value.payload_version == 1,value.envelope_version == "1",value.source_matches == true,
                  let zone = value.source_zone,let basis = value.basis else { throw WorldProjectionError.corruptRecord }
            let times = try JournalTimes(occurredMicroseconds:value.occurred_us,observedMicroseconds:value.observed_us,timeZone:IANATimeZone(identifier:zone))
            let recorded = try JournalTimes(occurredMicroseconds:nil,observedMicroseconds:value.recorded_us,timeZone:times.timeZone).observedAt
            return try WorldLocationFact(id:value.id,actorID:actorID,subjectID:subjectID,locationID:value.object_id,frameID:value.frame_id,
                valid:FactInterval(fromMicroseconds:value.valid_from_us,toMicroseconds:value.valid_to_us),
                transaction:FactInterval(fromMicroseconds:value.tx_from_us,toMicroseconds:value.tx_to_us),confidence:Confidence(value.confidence),basis:basis,
                sourceID:value.source_id,sourceEventID:value.provenance_event_id,timestamps:ObservationTimestamps(occurredAt:times.occurredAt,observedAt:times.observedAt,recordedAt:recorded,timeZone:times.timeZone))
        } catch { throw WorldProjectionError.corruptRecord }
    }
    private func transaction<Value: Sendable>(deadline: ContinuousClock.Instant, readOnly: Bool = false,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Value) async throws -> Value {
        try await withConnection(deadline: deadline) { connection in
            let begin: PostgresQuery = readOnly ? "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY" : "BEGIN"
            _ = try await BoundedPostgresQuery.rows(connection, begin)
            do {
                let value = try await body(connection)
                _ = try await BoundedPostgresQuery.rows(connection, "COMMIT")
                return value
            } catch {
                if (try? await BoundedPostgresQuery.rows(connection, "ROLLBACK")) == nil { connection.close().whenFailure { _ in } }
                throw error
            }
        }
    }
    private func withConnection<Value: Sendable>(deadline: ContinuousClock.Instant,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Value) async throws -> Value {
        let now = ContinuousClock.now
        guard deadline > now, deadline <= now.advanced(by: .seconds(5)) else { throw WorldProjectionError.unavailable }
        do {
            return try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask {
                    try await client.withConnection(isolation: nil) { connection in
                        try await withTaskCancellationHandler {
                            try Task.checkCancellation()
                            return try await body(connection)
                        } onCancel: { connection.close().whenFailure { _ in } }
                    }
                }
                group.addTask { try await Task.sleep(until: deadline); throw WorldProjectionError.unavailable }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch {
            try Task.checkCancellation()
            if let error = error as? WorldProjectionError { throw error }
            if let error = error as? PSQLError {
                switch error.serverInfo?[.sqlState] {
                case "23505": throw WorldProjectionError.versionConflict
                case "23503", "P0002": throw WorldProjectionError.notFound
                case "40001", "55000": throw WorldProjectionError.versionConflict
                case "22P02", "22P05", "22003", "22007", "22021", "23514": throw WorldProjectionError.invalidFact
                default: break
                }
            }
            throw WorldProjectionError.unavailable
        }
    }
}
