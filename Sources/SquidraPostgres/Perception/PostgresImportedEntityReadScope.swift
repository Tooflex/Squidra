import Foundation
import PostgresNIO

public enum ImportedEntityReadScopeError: Error, Equatable, Sendable { case timeout, cancelled, unavailable }

/// Host opt-in to read detected entities from one synthetic camera/scene/frame.
/// Membership comes from immutable, actor-linked observations, never client labels
/// or a mutable association cache. A scene's own entity ID is not a detection grant.
public struct PostgresImportedEntityReadScope: Sendable {
    private let client: PostgresClient
    public let policy: SyntheticScenePolicy
    public init(client: PostgresClient, policy: SyntheticScenePolicy) { self.client = client; self.policy = policy }
    public func contains(_ entityID: UUID, deadline: ContinuousClock.Instant) async throws -> Bool {
        guard entityID != policy.locationID else { return false }
        let now = ContinuousClock.now
        guard deadline > now, deadline <= now.advanced(by:.seconds(5)) else { throw ImportedEntityReadScopeError.timeout }
        do {
            return try await withThrowingTaskGroup(of:Bool.self) { group in
                group.addTask {
                    try await client.withConnection(isolation:nil) { connection in
                        try await withTaskCancellationHandler {
                            try Task.checkCancellation()
                            let rows = try await BoundedPostgresQuery.rows(connection,"""
                                SELECT EXISTS (
                                    SELECT 1 FROM world_event_entities l
                                    JOIN world_events e ON e.actor_id=l.actor_id AND e.event_id=l.event_id
                                    WHERE l.actor_id=\(policy.actorID) AND l.entity_id=\(entityID)
                                      AND e.entity_ids @> ARRAY[\(entityID)]::uuid[]
                                      AND e.event_type='perception.frame_imported' AND e.payload_version=1
                                      AND e.payload->>'journalSchemaVersion'='1'
                                      AND e.payload->'data'->>'schemaVersion'='1' AND e.payload->'data'->>'deployment'='synthetic'
                                      AND lower(e.payload->'data'->>'cameraId')=\(policy.cameraID.uuidString.lowercased())
                                      AND lower(e.payload->'data'->>'locationId')=\(policy.locationID.uuidString.lowercased())
                                      AND lower(e.payload->'data'->>'coordinateFrameId')=\(policy.coordinateFrameID.uuidString.lowercased())
                                      AND EXISTS (
                                          SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(e.payload->'data'->'detections')='array' THEN e.payload->'data'->'detections' ELSE '[]'::jsonb END) d
                                          WHERE lower(d->>'entityId')=\(entityID.uuidString.lowercased())
                                      )
                                )
                                """)
                            guard rows.count == 1 else { throw ImportedEntityReadScopeError.unavailable }
                            return try rows[0].decode(Bool.self)
                        } onCancel: { connection.close().whenFailure { _ in } }
                    }
                }
                group.addTask { try await ContinuousClock().sleep(until:deadline);throw ImportedEntityReadScopeError.timeout }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw ImportedEntityReadScopeError.unavailable };return value
            }
        } catch is CancellationError { throw Task.isCancelled ? ImportedEntityReadScopeError.cancelled : ImportedEntityReadScopeError.timeout }
        catch let error as ImportedEntityReadScopeError { throw error }
        catch { throw ImportedEntityReadScopeError.unavailable }
    }
}
