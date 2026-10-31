import Foundation
import PostgresNIO
import SquidraDomain
import SquidraWorld

public struct PostgresWorldRepository: WorldRepository {
    private let client: PostgresClient
    public init(client: PostgresClient) { self.client = client }
    public func append(_ event: WorldEventDraft, expectedVersion: Int64, idempotencyKey: String,
                       deadline: ContinuousClock.Instant) async throws -> JournalAppend {
        guard expectedVersion >= 0,expectedVersion < Int64.max,!idempotencyKey.isEmpty,idempotencyKey.utf8.count <= 256,
              idempotencyKey.trimmingCharacters(in:.whitespacesAndNewlines) == idempotencyKey,
              !idempotencyKey.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw WorldJournalError.invalidEvent }
        let raw = String(decoding:event.payload.bytes,as:UTF8.self)
        let occurredSeconds = event.times.occurredMicroseconds.map { Double($0/1_000_000) }
        let occurredFraction = event.times.occurredMicroseconds.map { $0%1_000_000 }
        let observed = event.times.observedMicroseconds,zone = event.times.timeZone.identifier
        return try await transaction(deadline:deadline) { connection in
            // Hold through COMMIT: qualified appends for one actor become visible
            // in sequence order, including across streams. Hash collisions only
            // serialize unrelated actors; they cannot merge their scopes.
            _ = try await BoundedPostgresQuery.rows(connection,"SELECT pg_advisory_xact_lock(hashtextextended(\(event.actorID.uuidString.lowercased()),1936818035))")
            let canonical = try await BoundedPostgresQuery.rows(connection,"SELECT \(raw)::jsonb::text")
            guard let row = canonical.first else { throw WorldJournalError.invalidEvent }
            let payload = try row.decode(String.self)
            do { _ = try JSONDocument(Data(payload.utf8),maximumBytes:65_536) }
            catch { throw WorldJournalError.invalidEvent }
            let existing = try await BoundedPostgresQuery.rows(connection,"""
                SELECT event_id,(entity_ids=\(event.entityIDs) AND event_type=\(event.type)
                    AND occurred_at IS NOT DISTINCT FROM (to_timestamp(\(occurredSeconds))+\(occurredFraction)*interval '1 microsecond')
                    AND observed_at=to_timestamp(\(Double(observed/1_000_000)))+\(observed%1_000_000)*interval '1 microsecond'
                    AND source_id=\(event.sourceID) AND confidence=\(event.confidence.value) AND payload_version=\(event.payloadVersion)
                    AND payload=jsonb_build_object('journalSchemaVersion','1','timeZone',\(zone)::text,'data',\(payload)::jsonb)
                    AND causation_id IS NOT DISTINCT FROM \(event.causationID)) AS matches
                FROM world_events WHERE actor_id=\(event.actorID) AND stream_id=\(event.streamID) AND idempotency_key=\(idempotencyKey)
                """)
            if let row = existing.first {
                let (id,matches) = try row.decode((UUID,Bool).self)
                guard matches else { throw WorldJournalError.idempotencyConflict }
                return try await JournalAppend(event:select(connection,actorID:event.actorID,id:id),created:false)
            }
            let versions = try await BoundedPostgresQuery.rows(connection,"SELECT coalesce(max(stream_version),0)::bigint FROM world_events WHERE actor_id=\(event.actorID) AND stream_id=\(event.streamID)")
            guard let row = versions.first,try row.decode(Int64.self) == expectedVersion else { throw WorldJournalError.versionConflict }
            _ = try await BoundedPostgresQuery.rows(connection,"""
                INSERT INTO world_events(event_id,actor_id,stream_id,stream_version,idempotency_key,entity_ids,event_type,
                    occurred_at,observed_at,source_id,confidence,payload_version,payload,causation_id,correlation_id)
                VALUES(\(event.id),\(event.actorID),\(event.streamID),\(expectedVersion+1),\(idempotencyKey),\(event.entityIDs),\(event.type),
                    to_timestamp(\(occurredSeconds))+\(occurredFraction)*interval '1 microsecond',
                    to_timestamp(\(Double(observed/1_000_000)))+\(observed%1_000_000)*interval '1 microsecond',
                    \(event.sourceID),\(event.confidence.value),\(event.payloadVersion),
                    jsonb_build_object('journalSchemaVersion','1','timeZone',\(zone)::text,'data',\(payload)::jsonb),\(event.causationID),\(event.correlationID))
                """)
            return try await JournalAppend(event:select(connection,actorID:event.actorID,id:event.id),created:true)
        }
    }
    public func page(actorID: UUID, afterSequence: Int64 = 0, cursor: JournalCursor? = nil, limit: Int = 64,
                     deadline: ContinuousClock.Instant) async throws -> JournalPage {
        guard (1...128).contains(limit),afterSequence >= 0,cursor.map({ $0.actorID == actorID && afterSequence == 0 }) ?? true else { throw WorldJournalError.invalidCursor }
        return try await withConnection(deadline:deadline) { connection in
            let highRows = try await BoundedPostgresQuery.rows(connection,"SELECT coalesce(max(sequence),0)::bigint FROM world_events WHERE actor_id=\(actorID)")
            guard let first = highRows.first else { throw WorldJournalError.corruptRecord }
            let maximum = try first.decode(Int64.self),through = cursor?.throughSequence ?? maximum,after = cursor?.afterSequence ?? afterSequence
            guard through <= maximum,after <= through else { throw WorldJournalError.invalidCursor }
            let rows = try await BoundedPostgresQuery.rows(connection,"""
                SELECT row_to_json(e)::text FROM (SELECT sequence,event_id,actor_id,stream_id,stream_version,entity_ids,event_type,
                    floor(extract(epoch FROM occurred_at)*1000000)::bigint AS occurred_us,
                    floor(extract(epoch FROM observed_at)*1000000)::bigint AS observed_us,
                    floor(extract(epoch FROM recorded_at)*1000000)::bigint AS recorded_us,source_id,confidence,payload_version,
                    payload->>'journalSchemaVersion' AS envelope_version,payload->>'timeZone' AS source_zone,(payload->'data')::text AS payload_json,
                    causation_id,correlation_id FROM world_events WHERE actor_id=\(actorID) AND sequence>\(after) AND sequence<=\(through)
                    ORDER BY sequence LIMIT \(limit+1)) AS e
                """)
            let events = try rows.prefix(limit).map { try decode($0,actorID:actorID) }
            let next = try rows.count > limit ? JournalCursor(actorID:actorID,afterSequence:events.last!.sequence,throughSequence:through) : nil
            return JournalPage(events:events,next:next,throughSequence:through)
        }
    }
    private struct Row: Decodable {
        let sequence: Int64,stream_version: Int64
        let event_id: UUID,actor_id: UUID,stream_id: UUID,entity_ids: [UUID],event_type: String
        let occurred_us: Int64?,observed_us: Int64,recorded_us: Int64
        let source_id: String,confidence: Double,payload_version: Int
        let envelope_version: String?,source_zone: String?,payload_json: String?
        let causation_id: UUID?,correlation_id: UUID
    }
    private func select(_ connection: PostgresConnection, actorID: UUID, id: UUID) async throws -> JournalEvent {
        let rows = try await BoundedPostgresQuery.rows(connection,"""
            SELECT row_to_json(e)::text FROM (SELECT sequence,event_id,actor_id,stream_id,stream_version,entity_ids,event_type,
                floor(extract(epoch FROM occurred_at)*1000000)::bigint AS occurred_us,
                floor(extract(epoch FROM observed_at)*1000000)::bigint AS observed_us,
                floor(extract(epoch FROM recorded_at)*1000000)::bigint AS recorded_us,source_id,confidence,payload_version,
                payload->>'journalSchemaVersion' AS envelope_version,payload->>'timeZone' AS source_zone,(payload->'data')::text AS payload_json,
                causation_id,correlation_id FROM world_events WHERE actor_id=\(actorID) AND event_id=\(id)) AS e
            """)
        guard let row = rows.first else { throw WorldJournalError.notFound };return try decode(row,actorID:actorID)
    }
    private func decode(_ row: PostgresRow, actorID: UUID) throws -> JournalEvent {
        do {
            let text = try row.decode(String.self)
            guard text.utf8.count <= 524_288 else { throw WorldJournalError.corruptRecord }
            let value = try JSONDecoder().decode(Row.self,from:Data(text.utf8))
            guard value.envelope_version == "1" else { throw WorldJournalError.unsupportedEvent }
            guard value.actor_id == actorID,let zone = value.source_zone,let payload = value.payload_json else { throw WorldJournalError.corruptRecord }
            let times = try JournalTimes(occurredMicroseconds:value.occurred_us,observedMicroseconds:value.observed_us,timeZone:IANATimeZone(identifier:zone))
            let event = try WorldEventDraft(id:value.event_id,actorID:actorID,streamID:value.stream_id,entityIDs:value.entity_ids,type:value.event_type,
                times:times,sourceID:value.source_id,confidence:Confidence(value.confidence),payloadVersion:value.payload_version,payload:Data(payload.utf8),
                causationID:value.causation_id,correlationID:value.correlation_id)
            return try JournalEvent(sequence:value.sequence,streamVersion:value.stream_version,draft:event,recordedMicroseconds:value.recorded_us)
        } catch WorldJournalError.unsupportedEvent { throw WorldJournalError.unsupportedEvent }
        catch { throw WorldJournalError.corruptRecord }
    }
    private func transaction<Value: Sendable>(deadline: ContinuousClock.Instant,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Value) async throws -> Value {
        try await withConnection(deadline: deadline) { connection in
            _ = try await BoundedPostgresQuery.rows(connection, "BEGIN")
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
        guard deadline > now, deadline <= now.advanced(by: .seconds(5)) else { throw WorldJournalError.unavailable }
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
                group.addTask { try await Task.sleep(until: deadline); throw WorldJournalError.unavailable }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch {
            try Task.checkCancellation()
            if let error = error as? WorldJournalError { throw error }
            if let error = error as? PSQLError {
                switch error.serverInfo?[.sqlState] {
                case "23505": throw WorldJournalError.idempotencyConflict
                case "23503", "P0002": throw WorldJournalError.notFound
                case "40001", "55000": throw WorldJournalError.versionConflict
                case "22P02", "22P05", "22003", "22007", "22021", "23514": throw WorldJournalError.invalidEvent
                default: break
                }
            }
            throw WorldJournalError.unavailable
        }
    }
}
