import Foundation
import PostgresNIO
import SquidraAgentRuntime
import SquidraCognition
import SquidraDomain

/// Saves only validated plans against the exact planning checkpoint.
public struct PostgresReadRunPlanStore: ReadRunPlanStore {
    private let client: PostgresClient
    public let actorID: UUID
    public init(client: PostgresClient, actorID: UUID) { self.client = client;self.actorID = actorID }
    public func save(snapshot: RunSnapshot, requestID: UUID,plan: PlannedRead, deadline: ContinuousClock.Instant) async throws {
        guard snapshot.actorID == actorID,snapshot.state == .planning,snapshot.steps == 0,snapshot.calls == 0 else { throw ReadRunTaskError.invalidState }
        let data = try ReadPlanArchive.encode(plan)
        guard data.count <= 65_536 else { throw ReadRunTaskError.invalidState }
        let run = snapshot.id,version = snapshot.version,request = requestID
        try await bounded(deadline) { c in
            // INSERT SELECT locks the original checkpoint while checking it.
            // The single statement commits the archive only for this exact state.
            let rows = try await BoundedPostgresQuery.rows(c,"""
                WITH checked AS MATERIALIZED (
                    SELECT r.id FROM agent_runs r JOIN read_run_tasks t ON t.actor_id=r.actor_id AND t.run_id=r.id
                    WHERE r.actor_id=\(actorID) AND r.id=\(run) AND r.version=\(version) AND r.state='PLANNING' AND r.step_count=0 AND r.tool_call_count=0
                        AND t.request_id=\(request) FOR SHARE OF r
                )
                INSERT INTO read_run_plans(actor_id,run_id,request_id,planning_version,archive)
                SELECT \(actorID),id,\(request),\(version),\(data) FROM checked
                ON CONFLICT(actor_id,run_id) DO NOTHING RETURNING run_id
                """)
            let stored = try await BoundedPostgresQuery.rows(c,"SELECT request_id,planning_version,archive FROM read_run_plans WHERE actor_id=\(actorID) AND run_id=\(run)")
            guard let row = stored.first else { throw ReadRunTaskError.conflict }
            let (storedRequest,storedVersion,storedData) = try row.decode((UUID,Int64,Data).self)
            guard storedRequest == request,storedVersion == version,storedData == data else { throw ReadRunTaskError.conflict }
            _ = rows // Identical retry also succeeds after later FSM progress.
        }
    }
    public func load(runID: UUID, deadline: ContinuousClock.Instant) async throws -> StoredReadRunPlan? {
        try await bounded(deadline) { c in
            let rows = try await BoundedPostgresQuery.rows(c,"SELECT request_id,planning_version,archive FROM read_run_plans WHERE actor_id=\(actorID) AND run_id=\(runID)")
            guard let row = rows.first else { return nil }
            let (request,version,data) = try row.decode((UUID,Int64,Data).self)
            _ = try JSONDocument(data,maximumBytes:65_536)
            return StoredReadRunPlan(actorID:actorID,runID:runID,requestID:request,planningVersion:version,archive:data)
        }
    }
    private func bounded<Value: Sendable>(_ deadline: ContinuousClock.Instant,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Value) async throws -> Value {
        let now = ContinuousClock.now
        guard deadline > now, deadline <= now.advanced(by:.seconds(5)) else { throw ReadRunTaskError.timeout }
        do {
            return try await withThrowingTaskGroup(of:Value.self) { group in
                group.addTask {
                    try await client.withConnection(isolation:nil) { connection in
                        try await withTaskCancellationHandler {
                            try Task.checkCancellation(); return try await body(connection)
                        } onCancel: { connection.close().whenFailure { _ in } }
                    }
                }
                group.addTask { try await ContinuousClock().sleep(until:deadline); throw ReadRunTaskError.timeout }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw ReadRunTaskError.unavailable }; return value
            }
        } catch is CancellationError { throw Task.isCancelled ? ReadRunTaskError.cancelled : ReadRunTaskError.timeout }
        catch let error as ReadRunTaskError { throw error }
        catch { throw ReadRunTaskError.unavailable }
    }
}
