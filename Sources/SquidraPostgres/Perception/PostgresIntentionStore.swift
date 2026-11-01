import Foundation
import PostgresNIO
import SquidraDomain
import SquidraMemory
import SquidraPerception
import SquidraWorld

/// Actor-scoped, one-shot internal watches. No external delivery or outbox worker.
public struct PostgresIntentionStore: IntentionStore {
    public let actorID: UUID
    private let repository: PostgresWorldRepository
    public init(actorID: UUID, client: PostgresClient) { self.actorID = actorID; self.repository = PostgresWorldRepository(client: client) }
    public func watch(entityID: UUID, key: String, deadline: ContinuousClock.Instant) async throws -> WatchIntention {
        guard !key.isEmpty,key.utf8.count <= 128,key.trimmingCharacters(in: .whitespacesAndNewlines) == key,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw WatchError.invalidRequest }
        let result: WatchIntention? = try await transaction(deadline) { c in
            try await lock(c)
            let old = try await BoundedPostgresQuery.rows(c,"SELECT id,entity_id,status,after_sequence FROM watch_intentions WHERE actor_id=\(actorID) AND request_key=\(key)")
            if let row = old.first {
                let value = try decode(row)
                guard value.entityID == entityID else { throw WorldJournalError.idempotencyConflict }
                return value
            }
            let active = try await BoundedPostgresQuery.rows(c,"SELECT count(*)::bigint FROM watch_intentions WHERE actor_id=\(actorID) AND status='active'")
            guard try active[0].decode(Int64.self) < 128 else { return nil }
            let high = try await BoundedPostgresQuery.rows(c,"SELECT coalesce(max(sequence),0)::bigint FROM world_events WHERE actor_id=\(actorID)")
            let after = try high[0].decode(Int64.self),id = UUID()
            _ = try await BoundedPostgresQuery.rows(c,"INSERT INTO watch_intentions(id,actor_id,entity_id,request_key,after_sequence,status) VALUES(\(id),\(actorID),\(entityID),\(key),\(after),'active')")
            return try WatchIntention(id: id,actorID: actorID,entityID: entityID,status: .active,afterSequence: after)
        }
        guard let result else { throw WatchError.capacityExceeded };return result
    }
    public func load(id: UUID, deadline: ContinuousClock.Instant) async throws -> WatchIntention? {
        try await transaction(deadline) { c in try await select(c,id: id) }
    }
    public func cancel(id: UUID, deadline: ContinuousClock.Instant) async throws -> WatchIntention {
        try await transaction(deadline) { c in
            try await lock(c)
            guard let watch = try await select(c,id: id) else { throw WorldJournalError.notFound }
            if watch.status == .active {
                _ = try await BoundedPostgresQuery.rows(c,"UPDATE watch_intentions SET status='cancelled' WHERE actor_id=\(actorID) AND id=\(id)")
                return try WatchIntention(id: id,actorID: actorID,entityID: watch.entityID,status: .cancelled,afterSequence: watch.afterSequence)
            }
            return watch
        }
    }
    public func deliver(intentionID: UUID, eventID: UUID, deadline: ContinuousClock.Instant) async throws -> WatchNotification? {
        try await transaction(deadline) { c in
            // Same lock as journal append: registration, cancellation and
            // delivery have a defined order against committed source events.
            try await lock(c)
            guard let watch = try await select(c,id: intentionID) else { throw WorldJournalError.notFound }
            let previous = try await BoundedPostgresQuery.rows(c,"SELECT notification_event_id FROM watch_notifications WHERE actor_id=\(actorID) AND intention_id=\(intentionID) AND source_event_id=\(eventID)")
            if let row = previous.first { return try WatchNotification(intentionID: intentionID,sourceEventID: eventID,notificationEventID: row.decode(UUID.self),created: false) }
            guard watch.status == .active else { return nil }
            let event = try await repository.select(c,actorID: actorID,id: eventID)
            guard event.sequence > watch.afterSequence,event.draft.type == "perception.movement_confirmed",event.draft.entityIDs == [watch.entityID] else { return nil }
            let epochs = try await BoundedPostgresQuery.rows(c,"SELECT state::text FROM movement_epochs WHERE actor_id=\(actorID) AND epoch_id=\(event.draft.correlationID) AND entity_id=\(watch.entityID)")
            guard let row = epochs.first else { return nil }
            let epoch = try MovementEpochCodec.decode(row.decode(String.self))
            guard try MovementPublisher.validates(event,epoch: epoch) else { return nil }
            let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
            let payload = try encoder.encode(NotificationPayload(intentionID: intentionID,entityID: watch.entityID,sourceEventID: eventID,movementSource: event.draft.sourceID))
            let draft = try WorldEventDraft(actorID: actorID,streamID: intentionID,entityIDs: [watch.entityID],type: "memory.watch_notified",
                times: event.draft.times,sourceID: "watch:"+intentionID.uuidString.lowercased(),confidence: event.draft.confidence,payloadVersion: 1,
                payload: payload,causationID: eventID,correlationID: event.draft.correlationID)
            let appended = try await repository.append(draft,expectedVersion: 0,idempotencyKey: "movement:"+eventID.uuidString.lowercased(),connection: c)
            _ = try await BoundedPostgresQuery.rows(c,"INSERT INTO watch_notifications(actor_id,intention_id,source_event_id,notification_event_id) VALUES(\(actorID),\(intentionID),\(eventID),\(appended.event.draft.id))")
            _ = try await BoundedPostgresQuery.rows(c,"UPDATE watch_intentions SET status='fulfilled' WHERE actor_id=\(actorID) AND id=\(intentionID)")
            return WatchNotification(intentionID: intentionID,sourceEventID: eventID,notificationEventID: appended.event.draft.id,created: true)
        }
    }
    private struct NotificationPayload: Encodable {
        let schemaVersion = "1", channel = "internal", basis = "inferred"
        let intentionID: UUID, entityID: UUID, sourceEventID: UUID, movementSource: String
    }
    private func lock(_ c: PostgresConnection) async throws {
        _ = try await BoundedPostgresQuery.rows(c,"SELECT pg_advisory_xact_lock(hashtextextended(\(actorID.uuidString.lowercased()),1936818035))")
    }
    private func select(_ c: PostgresConnection, id: UUID) async throws -> WatchIntention? {
        let rows = try await BoundedPostgresQuery.rows(c,"SELECT id,entity_id,status,after_sequence FROM watch_intentions WHERE actor_id=\(actorID) AND id=\(id)")
        return try rows.first.map(decode)
    }
    private func decode(_ row: PostgresRow) throws -> WatchIntention {
        let (id,entity,status,after) = try row.decode((UUID,UUID,String,Int64).self)
        guard let state = WatchStatus(rawValue: status) else { throw WorldJournalError.corruptRecord }
        return try WatchIntention(id: id,actorID: actorID,entityID: entity,status: state,afterSequence: after)
    }
    private func transaction<T: Sendable>(_ deadline: ContinuousClock.Instant,_ body: @escaping @Sendable (PostgresConnection) async throws -> T) async throws -> T {
        do { return try await repository.transaction(deadline: deadline,body) }
        catch is CancellationError { throw CancellationError() }
        catch let error as WorldJournalError {
            switch error {
            case .notFound: throw WatchError.notFound
            case .idempotencyConflict,.versionConflict: throw WatchError.conflict
            case .invalidEvent: throw WatchError.invalidRequest
            default: throw WatchError.unavailable
            }
        }
        catch { throw WatchError.unavailable }
    }
}
