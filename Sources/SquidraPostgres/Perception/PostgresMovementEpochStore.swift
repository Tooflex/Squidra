import Foundation
import PostgresNIO
import SquidraPerception

/// Actor-bound sealed epoch store. Existing inputs are never overwritten.
public struct PostgresMovementEpochStore: MovementEpochStore {
    private let client: PostgresClient
    public let actorID: UUID
    public init(client: PostgresClient, actorID: UUID) { self.client = client; self.actorID = actorID }
    public func save(_ epoch: MovementEpoch, deadline: ContinuousClock.Instant) async throws {
        guard epoch.detector.actorID == actorID else { throw MovementEpochError.invalidState }
        let text = try MovementEpochCodec.encode(epoch),id = epoch.detector.epochID,entity = epoch.detector.entityID
        try await bounded(deadline) { connection in
            _ = try await BoundedPostgresQuery.rows(connection,"""
                INSERT INTO movement_epochs(actor_id,epoch_id,entity_id,state) VALUES(\(actorID),\(id),\(entity),\(text)::jsonb)
                ON CONFLICT(actor_id,epoch_id) DO NOTHING
                """)
            let rows = try await BoundedPostgresQuery.rows(connection,"SELECT state=\(text)::jsonb FROM movement_epochs WHERE actor_id=\(actorID) AND epoch_id=\(id)")
            guard let row = rows.first,try row.decode(Bool.self) else { throw MovementEpochError.conflict }
        }
    }
    public func load(epochID: UUID, deadline: ContinuousClock.Instant) async throws -> MovementEpoch? {
        try await bounded(deadline) { connection in
            let rows = try await BoundedPostgresQuery.rows(connection,"SELECT entity_id,state::text FROM movement_epochs WHERE actor_id=\(actorID) AND epoch_id=\(epochID)")
            guard let row = rows.first else { return nil }
            let (entity,text) = try row.decode((UUID,String).self),epoch = try MovementEpochCodec.decode(text)
            guard epoch.detector.actorID == actorID,epoch.detector.epochID == epochID,epoch.detector.entityID == entity else { throw MovementEpochError.invalidState }
            return epoch
        }
    }
    private func bounded<Value: Sendable>(_ deadline: ContinuousClock.Instant,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Value) async throws -> Value {
        let now = ContinuousClock.now
        guard deadline > now, deadline <= now.advanced(by:.seconds(5)) else { throw MovementEpochError.timeout }
        do {
            return try await withThrowingTaskGroup(of:Value.self) { group in
                group.addTask {
                    try await client.withConnection(isolation:nil) { connection in
                        try await withTaskCancellationHandler {
                            try Task.checkCancellation(); return try await body(connection)
                        } onCancel: { connection.close().whenFailure { _ in } }
                    }
                }
                group.addTask { try await ContinuousClock().sleep(until:deadline); throw MovementEpochError.timeout }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw MovementEpochError.unavailable }; return value
            }
        } catch is CancellationError { throw Task.isCancelled ? MovementEpochError.cancelled : MovementEpochError.timeout }
        catch let error as MovementEpochError { throw error }
        catch { throw MovementEpochError.unavailable }
    }
}
