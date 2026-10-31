import Foundation
import PostgresNIO
import SquidraPerception

/// Durable bounded association cache, fixed to one authenticated actor/camera.
/// Configure the resolver policy with maximumTracks <= 32 for this adapter.
public struct PostgresEntityAssociationStore: EntityAssociationStore {
    public static let maximumTracks = 32
    private let client: PostgresClient
    public let actorID: UUID, cameraID: UUID
    public init(client: PostgresClient, actorID: UUID, cameraID: UUID) { self.client = client; self.actorID = actorID; self.cameraID = cameraID }
    public func load(actorID: UUID, cameraID: UUID, deadline: ContinuousClock.Instant) async throws -> EntityAssociationState? {
        guard actorID == self.actorID, cameraID == self.cameraID else { throw EntityAssociationError.invalidState }
        return try await bounded(deadline) { connection in try await select(connection) }
    }
    public func compareAndSwap(_ state: EntityAssociationState, expectedRevision: Int64?, deadline: ContinuousClock.Instant) async throws {
        let context = state.resolution.context
        guard context.actorID == actorID, context.cameraID == cameraID,
              expectedRevision.map({ $0 > 0 && $0 < Int64.max && state.revision == $0+1 }) ?? (state.revision == 1) else { throw EntityAssociationError.invalidState }
        let text = try AssociationStateCodec.encode(state), ids = state.tracks.map(\.entityID)
        try await bounded(deadline) { connection in
            _ = try await BoundedPostgresQuery.rows(connection,"BEGIN")
            do {
                _ = try await BoundedPostgresQuery.rows(connection,"SELECT pg_advisory_xact_lock(hashtextextended(\(actorID.uuidString.lowercased()+":"+cameraID.uuidString.lowercased()),1936818040))")
                let current = try await select(connection)
                guard current?.revision == expectedRevision else { throw EntityAssociationError.conflict }
                if !ids.isEmpty {
                    _ = try await BoundedPostgresQuery.rows(connection,"""
                        INSERT INTO world_entities(id,actor_id,kind)
                        SELECT entity,\(actorID),'perception_candidate' FROM unnest(\(ids)::uuid[]) AS entity
                        ON CONFLICT (id) DO NOTHING
                        """)
                    let owned = try await BoundedPostgresQuery.rows(connection,"SELECT id FROM world_entities WHERE actor_id=\(actorID) AND id=ANY(\(ids)::uuid[])")
                    guard owned.count == ids.count else { throw EntityAssociationError.invalidState }
                }
                let changed = try await BoundedPostgresQuery.rows(connection,"""
                    INSERT INTO entity_associations(actor_id,camera_id,revision,schema_version,state)
                    VALUES(\(actorID),\(cameraID),\(state.revision),1,\(text)::jsonb)
                    ON CONFLICT(actor_id,camera_id) DO UPDATE SET revision=EXCLUDED.revision,state=EXCLUDED.state
                    WHERE entity_associations.revision=\(expectedRevision ?? 0)
                    RETURNING revision
                    """)
                guard changed.count == 1 else { throw EntityAssociationError.conflict }
                _ = try await BoundedPostgresQuery.rows(connection,"COMMIT")
            } catch {
                if (try? await BoundedPostgresQuery.rows(connection,"ROLLBACK")) == nil { connection.close().whenFailure { _ in } }
                throw error
            }
        }
    }
    private func select(_ connection: PostgresConnection) async throws -> EntityAssociationState? {
        let rows = try await BoundedPostgresQuery.rows(connection,"SELECT revision,schema_version,state::text FROM entity_associations WHERE actor_id=\(actorID) AND camera_id=\(cameraID)")
        guard let row = rows.first else { return nil }
        guard rows.count == 1 else { throw EntityAssociationError.invalidState }
        let (revision,version,text) = try row.decode((Int64,Int,String).self)
        let state = try AssociationStateCodec.decode(text), context = state.resolution.context
        guard version == 1, state.revision == revision, context.actorID == actorID, context.cameraID == cameraID else { throw EntityAssociationError.invalidState }
        let ids = state.tracks.map(\.entityID)
        if !ids.isEmpty {
            let owned = try await BoundedPostgresQuery.rows(connection,"SELECT id FROM world_entities WHERE actor_id=\(actorID) AND id=ANY(\(ids)::uuid[])")
            guard owned.count == ids.count else { throw EntityAssociationError.invalidState }
        }
        return state
    }
    private func bounded<Value: Sendable>(_ deadline: ContinuousClock.Instant,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Value) async throws -> Value {
        let now = ContinuousClock.now
        guard deadline > now, deadline <= now.advanced(by:.seconds(5)) else { throw EntityAssociationError.timeout }
        do {
            return try await withThrowingTaskGroup(of:Value.self) { group in
                group.addTask {
                    try await client.withConnection(isolation:nil) { connection in
                        try await withTaskCancellationHandler {
                            try Task.checkCancellation(); return try await body(connection)
                        } onCancel: { connection.close().whenFailure { _ in } }
                    }
                }
                group.addTask { try await ContinuousClock().sleep(until:deadline); throw EntityAssociationError.timeout }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw EntityAssociationError.unavailable }; return value
            }
        } catch is CancellationError { throw Task.isCancelled ? EntityAssociationError.cancelled : EntityAssociationError.timeout }
        catch let error as EntityAssociationError { throw error }
        catch { throw EntityAssociationError.unavailable }
    }
}
