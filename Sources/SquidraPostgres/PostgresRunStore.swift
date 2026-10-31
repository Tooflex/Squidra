import Foundation
import PostgresNIO
import SquidraAgentRuntime

/// Durable runtime checkpoints. Uses T03's version guards and trusted development roles;
/// it is not a replacement for application actor authentication or DB grants.
public struct PostgresRunStore: RunStore {
    private let client: PostgresClient
    public init(client: PostgresClient) { self.client = client }

    public func create(_ snapshot: RunSnapshot, deadline: ContinuousClock.Instant) async throws {
        try snapshot.validate()
        guard snapshot.state == .created, snapshot.version == 1, snapshot.steps == 0, snapshot.calls == 0,
              snapshot.activeMilliseconds == 0, snapshot.maximumDelegationDepth == 0 else { throw RunStoreError.corruptCheckpoint }
        let checkpoint = try encoded(snapshot)
        try await withConnection(deadline: deadline) { connection in
            _ = try await BoundedPostgresQuery.rows(connection, """
                INSERT INTO agent_runs(id,actor_id,state,version,checkpoint,trace_id,deadline,active_budget_ms)
                VALUES(\(snapshot.id),\(snapshot.actorID),\(snapshot.state.rawValue),1,\(checkpoint)::jsonb,
                       \(snapshot.traceID),to_timestamp(\(snapshot.deadlineSecondsSince1970)),\(snapshot.budget.activeMilliseconds))
                """)
        }
    }

    public func load(actorID: UUID, runID: UUID, deadline: ContinuousClock.Instant) async throws -> RunSnapshot {
        try await withConnection(deadline: deadline) { connection in
            try await select(connection, actorID: actorID, runID: runID, lock: false)
        }
    }

    public func compareAndSet(_ snapshot: RunSnapshot, expectedVersion: Int64, deadline: ContinuousClock.Instant) async throws {
        try snapshot.validate()
        guard expectedVersion > 0, expectedVersion < Int64.max, snapshot.version == expectedVersion+1 else { throw RunStoreError.conflict }
        let checkpoint = try encoded(snapshot)
        try await withConnection(deadline: deadline) { connection in
            _ = try await BoundedPostgresQuery.rows(connection, "BEGIN")
            do {
                let current = try await select(connection, actorID: snapshot.actorID, runID: snapshot.id, lock: true)
                guard current.version == expectedVersion else { throw RunStoreError.conflict }
                guard !current.state.isTerminal else { throw RunStoreError.terminal }
                guard current.traceID == snapshot.traceID, current.budget == snapshot.budget,
                      current.state == snapshot.state || current.state.permits(snapshot.state),
                      snapshot.steps >= current.steps, snapshot.calls >= current.calls,
                      snapshot.activeMilliseconds >= current.activeMilliseconds,
                      snapshot.maximumDelegationDepth >= current.maximumDelegationDepth else { throw RunStoreError.corruptCheckpoint }
                let changed = try await BoundedPostgresQuery.rows(connection, """
                    UPDATE agent_runs SET state=\(snapshot.state.rawValue),substate=\(snapshot.substate?.rawValue),
                        version=\(snapshot.version),checkpoint=\(checkpoint)::jsonb,
                        terminal_code=\(snapshot.terminalCode?.rawValue),deadline=to_timestamp(\(snapshot.deadlineSecondsSince1970)),
                        step_count=\(snapshot.steps)::integer,tool_call_count=\(snapshot.calls)::integer,
                        active_elapsed_ms=\(snapshot.activeMilliseconds)
                    WHERE actor_id=\(snapshot.actorID) AND id=\(snapshot.id) AND version=\(expectedVersion) RETURNING id
                    """)
                guard changed.count == 1 else { throw RunStoreError.conflict }
                _ = try await BoundedPostgresQuery.rows(connection, "COMMIT")
            } catch {
                // A cancelled lease is already closed; a safe rollback must not
                // enqueue a new async query onto that closed channel.
                if (try? await BoundedPostgresQuery.rows(connection, "ROLLBACK")) == nil {
                    connection.close().whenFailure { _ in }
                }
                throw error
            }
        }
    }

    private func encoded(_ snapshot: RunSnapshot) throws -> String {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 65_536 else { throw RunStoreError.corruptCheckpoint }
        return String(decoding: data, as: UTF8.self)
    }
    private func select(_ connection: PostgresConnection, actorID: UUID, runID: UUID, lock: Bool) async throws -> RunSnapshot {
        let query: PostgresQuery = lock ? """
            SELECT checkpoint::text,state,substate,version,step_count::bigint,tool_call_count::bigint,
                   active_elapsed_ms,active_budget_ms,trace_id,terminal_code
            FROM agent_runs WHERE actor_id=\(actorID) AND id=\(runID) FOR UPDATE
            """ : """
            SELECT checkpoint::text,state,substate,version,step_count::bigint,tool_call_count::bigint,
                   active_elapsed_ms,active_budget_ms,trace_id,terminal_code
            FROM agent_runs WHERE actor_id=\(actorID) AND id=\(runID)
            """
        let rows = try await BoundedPostgresQuery.rows(connection, query)
        guard let row = rows.first else { throw RunStoreError.notFound }
        do {
            let (json, state, substate, version, steps, calls, elapsed, budget, trace, terminal) = try row.decode(
                (String, String, String?, Int64, Int64, Int64, Int64, Int64, UUID, String?).self)
            let data = Data(json.utf8)
            guard data.count <= 65_536 else { throw RunStoreError.corruptCheckpoint }
            let snapshot = try JSONDecoder().decode(RunSnapshot.self, from: data)
            try snapshot.validate()
            guard snapshot.id == runID, snapshot.actorID == actorID, snapshot.state.rawValue == state,
                  snapshot.substate?.rawValue == substate, snapshot.version == version, Int64(snapshot.steps) == steps, Int64(snapshot.calls) == calls,
                  snapshot.activeMilliseconds == elapsed, snapshot.budget.activeMilliseconds == budget,
                  snapshot.traceID == trace, snapshot.terminalCode?.rawValue == terminal else { throw RunStoreError.corruptCheckpoint }
            return snapshot
        } catch { throw RunStoreError.corruptCheckpoint }
    }

    private func withConnection<Value: Sendable>(deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable (PostgresConnection) async throws -> Value) async throws -> Value {
        let now = ContinuousClock.now
        guard deadline > now, deadline <= now.advanced(by: .seconds(5)) else { throw RunStoreError.unavailable }
        do {
            return try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask {
                    try await client.withConnection(isolation: nil) { connection in
                        try await withTaskCancellationHandler {
                            try Task.checkCancellation()
                            return try await operation(connection)
                        } onCancel: { connection.close().whenFailure { _ in } }
                    }
                }
                group.addTask { try await Task.sleep(until: deadline); throw RunStoreError.unavailable }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch {
            try Task.checkCancellation()
            if let error = error as? RunStoreError { throw error }
            if let error = error as? PSQLError {
                switch error.serverInfo?[.sqlState] {
                case "23505", "40001": throw RunStoreError.conflict
                case "55000": throw RunStoreError.terminal
                case "P0002": throw RunStoreError.notFound
                default: break
                }
            }
            throw RunStoreError.unavailable
        }
    }
}
