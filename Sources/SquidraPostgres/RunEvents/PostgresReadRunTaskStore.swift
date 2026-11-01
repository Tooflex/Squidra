import Foundation
import PostgresNIO
import SquidraAgentRuntime

/// Scoped immutable task storage; contains private user text, never logs it.
public struct PostgresReadRunTaskStore: ReadRunTaskStore {
    private let client: PostgresClient
    public let actorID: UUID
    public init(client: PostgresClient, actorID: UUID) { self.client = client;self.actorID = actorID }
    public func save(_ task: StoredReadRunTask, deadline: ContinuousClock.Instant) async throws {
        guard task.request.actorID == actorID else { throw ReadRunTaskError.invalidState }
        let text = try ReadRunTaskCodec.encode(task),id = task.request.runID,thread = task.threadID,request = task.request.requestID
        try await bounded(deadline) { c in
            _ = try await BoundedPostgresQuery.rows(c,"INSERT INTO read_run_tasks(actor_id,run_id,thread_id,request_id,task) VALUES(\(actorID),\(id),\(thread),\(request),\(text)::jsonb) ON CONFLICT(actor_id,run_id) DO NOTHING")
            let rows = try await BoundedPostgresQuery.rows(c,"SELECT task=\(text)::jsonb FROM read_run_tasks WHERE actor_id=\(actorID) AND run_id=\(id)")
            guard let row = rows.first,try row.decode(Bool.self) else { throw ReadRunTaskError.conflict }
        }
    }
    public func load(runID: UUID, deadline: ContinuousClock.Instant) async throws -> StoredReadRunTask? {
        try await bounded(deadline) { c in
            let rows = try await BoundedPostgresQuery.rows(c,"SELECT task::text,thread_id,request_id FROM read_run_tasks WHERE actor_id=\(actorID) AND run_id=\(runID)")
            guard let row = rows.first else { return nil }
            let (text,thread,request) = try row.decode((String,UUID,UUID).self),task = try ReadRunTaskCodec.decode(text)
            guard task.request.actorID == actorID,task.request.runID == runID,task.threadID == thread,task.request.requestID == request else { throw ReadRunTaskError.invalidState }
            return task
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
