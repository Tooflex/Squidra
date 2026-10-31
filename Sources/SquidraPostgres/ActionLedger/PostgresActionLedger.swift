import Foundation
import PostgresNIO
import SquidraTools

public struct PostgresActionLedger: ActionLedgerStore {
    private let client: PostgresClient
    public init(client: PostgresClient) { self.client = client }

    public func reserve(_ command: ActionCommand, deadline: ContinuousClock.Instant) async throws -> ActionReservation {
        let arguments = String(decoding: command.arguments, as: UTF8.self)
        let scope = String(decoding: try JSONEncoder().encode(command.scope), as: UTF8.self)
        return try await transaction(deadline: deadline) { connection in
            let rows = try await BoundedPostgresQuery.rows(connection, """
                SELECT ledger_id,created FROM reserve_action(\(command.actorID),\(command.runID),\(command.tool.qualifiedName),
                    \(command.idempotencyKey),\(command.tool.version),\(command.target),\(arguments)::jsonb,\(scope)::jsonb,
                    decode(\(command.fingerprintHex),'hex'))
                """)
            guard let row = rows.first, rows.count == 1 else { throw ActionLedgerError.corruptRecord }
            let (id, created) = try row.decode((UUID, Bool).self)
            let record = try await select(connection, actorID: command.actorID, id: id, lock: false)
            return ActionReservation(record: record, created: created)
        }
    }
    public func load(actorID: UUID, id: UUID, deadline: ContinuousClock.Instant) async throws -> ActionRecord {
        try await withConnection(deadline: deadline) { try await select($0, actorID: actorID, id: id, lock: false) }
    }
    public func update(_ record: ActionRecord, to status: ActionStatus, result: ActionResult?, providerReference: String?,
                       deadline: ContinuousClock.Instant) async throws -> ActionRecord {
        try result?.validate()
        guard status.isFinal == (result != nil), result.map({ $0.status == status }) ?? true else { throw ActionLedgerError.invalidOutcome }
        return try await transaction(deadline: deadline) { connection in
            let current = try await select(connection, actorID: record.command.actorID, id: record.id, lock: true)
            guard current.command.fingerprint == record.command.fingerprint,
                  current.command.idempotencyKey == record.command.idempotencyKey else { throw ActionLedgerError.conflict }
            guard current.version == record.version, current.version < Int64.max else { throw ActionLedgerError.versionConflict }
            let allowed = (current.status == .reserved && status == .pending)
                || (current.status == .pending && (status == .unknown || status.isFinal))
                || (current.status == .unknown && status.isFinal)
            guard allowed else { throw current.status == .unknown ? ActionLedgerError.reconciliationRequired : .versionConflict }
            let next = try ActionRecord(id: current.id, command: current.command, status: status, version: current.version+1,
                result: result, providerReference: providerReference ?? current.providerReference)
            let encoded = try result.map { value in
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                return String(decoding: try encoder.encode(value), as: UTF8.self)
            }
            let rows = try await BoundedPostgresQuery.rows(connection, """
                UPDATE action_ledger SET status=\(status.rawValue),result=\(encoded)::jsonb,
                    provider_reference=\(next.providerReference),version=version+1
                WHERE actor_id=\(current.command.actorID) AND id=\(current.id) AND version=\(current.version) RETURNING id
                """)
            guard rows.count == 1 else { throw ActionLedgerError.versionConflict }
            if status.isFinal {
                let payload = try JSONSerialization.data(withJSONObject: ["schemaVersion":"1","kind":"action.result",
                    "ledgerId":current.id.uuidString.lowercased(),"status":status.rawValue,"fingerprint":current.command.fingerprintHex], options: [.sortedKeys])
                let text = String(decoding: payload, as: UTF8.self)
                _ = try await BoundedPostgresQuery.rows(connection, """
                    INSERT INTO outbox(actor_id,run_id,ledger_id,deduplication_key,payload)
                    VALUES(\(current.command.actorID),\(current.command.runID),\(current.id),
                        \("action-result:"+current.id.uuidString.lowercased()),\(text)::jsonb)
                    """)
            }
            return next
        }
    }

    private struct Row: Decodable {
        let id: UUID, actor_id: UUID, run_id: UUID
        let tool_name: String, tool_version: String, idempotency_key: String, target: String
        let arguments_json: String, scope_json: String, command_hash: String
        let status: ActionStatus, result_json: String?, provider_reference: String?, version: Int64
    }
    private func select(_ connection: PostgresConnection, actorID: UUID, id: UUID, lock: Bool) async throws -> ActionRecord {
        let query: PostgresQuery = lock ? """
            SELECT row_to_json(r)::text FROM (
                SELECT id,actor_id,run_id,tool_name,tool_version,idempotency_key,target,arguments::text AS arguments_json,
                    scope::text AS scope_json,encode(command_hash,'hex') AS command_hash,status,result::text AS result_json,provider_reference,version
                FROM action_ledger WHERE actor_id=\(actorID) AND id=\(id) FOR UPDATE) AS r
            """ : """
            SELECT row_to_json(r)::text FROM (
                SELECT id,actor_id,run_id,tool_name,tool_version,idempotency_key,target,arguments::text AS arguments_json,
                    scope::text AS scope_json,encode(command_hash,'hex') AS command_hash,status,result::text AS result_json,provider_reference,version
                FROM action_ledger WHERE actor_id=\(actorID) AND id=\(id)) AS r
            """
        let rows = try await BoundedPostgresQuery.rows(connection, query)
        guard let row = rows.first else { throw ActionLedgerError.notFound }
        do {
            let text = try row.decode(String.self)
            guard text.utf8.count <= 4_194_304 else { throw ActionLedgerError.corruptRecord }
            let value = try JSONDecoder().decode(Row.self, from: Data(text.utf8))
            let name = value.tool_name.split(separator: ".", omittingEmptySubsequences: false)
            guard value.actor_id == actorID, value.id == id, name.count == 2 else { throw ActionLedgerError.corruptRecord }
            let command = try ActionCommand(actorID: actorID, runID: value.run_id,
                tool: ToolID(namespace: String(name[0]), name: String(name[1]), version: value.tool_version),
                idempotencyKey: value.idempotency_key, target: value.target, arguments: Data(value.arguments_json.utf8),
                scope: JSONDecoder().decode([String].self, from: Data(value.scope_json.utf8)))
            guard command.fingerprintHex == value.command_hash else { throw ActionLedgerError.corruptRecord }
            let result = try value.result_json.map { try JSONDecoder().decode(ActionResult.self, from: Data($0.utf8)) }
            return try ActionRecord(id: id, command: command, status: value.status, version: value.version,
                result: result, providerReference: value.provider_reference)
        } catch { throw ActionLedgerError.corruptRecord }
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
        guard deadline > now, deadline <= now.advanced(by: .seconds(5)) else { throw ActionLedgerError.unavailable }
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
                group.addTask { try await Task.sleep(until: deadline); throw ActionLedgerError.unavailable }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch {
            try Task.checkCancellation()
            if let error = error as? ActionLedgerError { throw error }
            if let error = error as? PSQLError {
                switch error.serverInfo?[.sqlState] {
                case "23505": throw ActionLedgerError.conflict
                case "23503", "P0002": throw ActionLedgerError.notFound
                case "40001", "55000": throw ActionLedgerError.versionConflict
                default: break
                }
            }
            throw ActionLedgerError.unavailable
        }
    }
}
