import Foundation
import PostgresNIO
import SquidraAgentRuntime
import SquidraDomain
import SquidraTools

public struct PostgresReadRunToolResultStore: ReadRunToolResultStore {
    private let client: PostgresClient
    public let actorID: UUID
    public init(client: PostgresClient,actorID: UUID) { self.client = client;self.actorID = actorID }
    public func save(snapshot: RunSnapshot,requestID: UUID,command: ActionCommand,result: UntrustedToolResult,deadline: ContinuousClock.Instant) async throws {
        guard snapshot.actorID == actorID,command.actorID == actorID,command.runID == snapshot.id,
              snapshot.state == .executingTool,snapshot.steps == 1,snapshot.calls == 1,
              result.tool == command.tool,["world.get_entity_location@1.0.0","world.get_changes@1.0.0"].contains(result.tool.identifier),
              command.idempotencyKey == "read:"+snapshot.id.uuidString.lowercased() else { throw ReadRunTaskError.invalidState }
        _ = try JSONDocument(result.payload,maximumBytes:65_536)
        let run = snapshot.id,version = snapshot.version,key = command.idempotencyKey,fingerprint = command.fingerprintHex
        let tool = result.tool.identifier,call = result.callID,data = result.payload
        try await bounded(deadline) { c in
            let rows = try await BoundedPostgresQuery.rows(c,"""
                WITH checked AS MATERIALIZED (
                    SELECT r.id FROM agent_runs r JOIN read_run_tasks t ON t.actor_id=r.actor_id AND t.run_id=r.id
                    WHERE r.actor_id=\(actorID) AND r.id=\(run) AND r.version=\(version) AND r.state='EXECUTING_TOOL'
                        AND r.step_count=1 AND r.tool_call_count=1 AND t.request_id=\(requestID)
                        AND r.checkpoint->'iteration'->>'semanticDigest'=\(fingerprint)
                        AND r.checkpoint->'invocation'->>'key'=\(key)
                        AND r.checkpoint->'invocation'->>'inFlight'='true'
                        AND r.checkpoint->'invocation'->>'attempts'='1' FOR SHARE OF r
                )
                INSERT INTO read_run_tool_results(actor_id,run_id,request_id,call_id,execution_version,command_fingerprint,tool_identifier,payload)
                SELECT \(actorID),id,\(requestID),\(call),\(version),\(fingerprint),\(tool),\(data) FROM checked
                ON CONFLICT(actor_id,run_id) DO NOTHING RETURNING run_id
                """)
            let stored = try await BoundedPostgresQuery.rows(c,"SELECT request_id,call_id,execution_version,command_fingerprint,tool_identifier,payload FROM read_run_tool_results WHERE actor_id=\(actorID) AND run_id=\(run)")
            guard let row = stored.first else { throw ReadRunTaskError.conflict }
            let (r,c,v,f,t,p) = try row.decode((UUID,UUID,Int64,String,String,Data).self)
            guard r == requestID,c == call,v == version,f == fingerprint,t == tool,p == data else { throw ReadRunTaskError.conflict }
            _ = rows // Exact retry remains valid after later runtime progress.
        }
    }
    public func load(runID: UUID,deadline: ContinuousClock.Instant) async throws -> StoredReadRunToolResult? {
        try await bounded(deadline) { c in
            let rows = try await BoundedPostgresQuery.rows(c,"SELECT request_id,call_id,execution_version,command_fingerprint,tool_identifier,payload FROM read_run_tool_results WHERE actor_id=\(actorID) AND run_id=\(runID)")
            guard let row = rows.first else { return nil }
            let (r,call,v,f,t,p) = try row.decode((UUID,UUID,Int64,String,String,Data).self)
            _ = try JSONDocument(p,maximumBytes:65_536)
            return StoredReadRunToolResult(actorID:actorID,runID:runID,requestID:r,callID:call,executionVersion:v,commandFingerprint:f,toolIdentifier:t,payload:p)
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
