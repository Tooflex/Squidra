import Foundation
import PostgresNIO
import SquidraSecurity

public struct PostgresApprovalStore: ApprovalStore {
    private let client: PostgresClient
    public init(client: PostgresClient) { self.client = client }
    public func request(_ binding: ApprovalBinding, nowMilliseconds: Int64, ttlMilliseconds: Int64,
                        deadline: ContinuousClock.Instant) async throws -> ApprovalRecord {
        guard (1...600_000).contains(ttlMilliseconds) else { throw ApprovalError.invalidRequest }
        return try await transaction(deadline:deadline) { connection in
            let hash = binding.commandHash.map { String(format:"%02x",$0) }.joined()
            let rows = try await BoundedPostgresQuery.rows(connection,"""
                SELECT status FROM action_ledger WHERE actor_id=\(binding.actorID) AND run_id=\(binding.runID)
                    AND id=\(binding.ledgerID) AND command_hash=decode(\(hash),'hex') FOR UPDATE
                """)
            guard let row = rows.first else { throw ApprovalError.notFound }
            let status = try row.decode(String.self)
            let existing = try await BoundedPostgresQuery.rows(connection,"""
                SELECT id FROM approvals WHERE actor_id=\(binding.actorID) AND ledger_id=\(binding.ledgerID)
                    ORDER BY requested_at,id LIMIT 1
                """)
            if let row = existing.first {
                let record = try await select(connection,actorID:binding.actorID,id:row.decode(UUID.self),lock:false)
                guard record.binding == binding else { throw ApprovalError.conflict }
                return record
            }
            guard status == "reserved" else { throw ApprovalError.conflict }
            let now = try await serverNow(connection)
            // No client timestamp is trusted; large host/DB skew fails closed.
            guard nowMilliseconds >= now-5_000, nowMilliseconds <= now+5_000 else { throw ApprovalError.unavailable }
            let record = try ApprovalRecord(id:UUID(),binding:binding,requestedAtMilliseconds:now,expiresAtMilliseconds:now+ttlMilliseconds)
            let digest = record.digest.map { String(format:"%02x",$0) }.joined()
            let expiry = record.expiresAtMilliseconds
            _ = try await BoundedPostgresQuery.rows(connection,"""
                INSERT INTO approvals(id,actor_id,run_id,ledger_id,command_hash,approval_digest,requested_at,expires_at)
                VALUES(\(record.id),\(binding.actorID),\(binding.runID),\(binding.ledgerID),decode(\(hash),'hex'),decode(\(digest),'hex'),
                    to_timestamp(\(Double(now/1_000)))+\(now%1_000)*interval '1 millisecond',
                    to_timestamp(\(Double(expiry/1_000)))+\(expiry%1_000)*interval '1 millisecond')
                """)
            return record
        }
    }
    public func load(actorID: UUID, id: UUID, deadline: ContinuousClock.Instant) async throws -> ApprovalObservation {
        try await withConnection(deadline:deadline) { connection in
            let record = try await select(connection,actorID:actorID,id:id,lock:false)
            return try await ApprovalObservation(record:record,observedAtMilliseconds:serverNow(connection))
        }
    }
    public func resolve(_ record: ApprovalRecord, response: ApprovalResponse, approverID: UUID, nowMilliseconds: Int64,
                        deadline: ContinuousClock.Instant) async throws -> ApprovalRecord {
        try await transaction(deadline:deadline) { connection in
            let current = try await select(connection,actorID:record.binding.actorID,id:record.id,lock:true)
            guard current.binding == record.binding, current.digest == record.digest else { throw ApprovalError.conflict }
            if current.decision != .pending {
                guard current.decision == response.decision, current.approverID == approverID else { throw ApprovalError.conflict }
                return current
            }
            guard current.version == record.version, current.version < Int64.max else { throw ApprovalError.conflict }
            let now = max(try await serverNow(connection),nowMilliseconds,current.requestedAtMilliseconds)
            let decision = now >= current.expiresAtMilliseconds ? ApprovalDecision.expired : response.decision
            let principal = decision == .expired ? nil : approverID
            let next = try ApprovalRecord(id:current.id,binding:current.binding,requestedAtMilliseconds:current.requestedAtMilliseconds,
                expiresAtMilliseconds:current.expiresAtMilliseconds,decision:decision,approverID:principal,decidedAtMilliseconds:now,version:current.version+1)
            let rows = try await BoundedPostgresQuery.rows(connection,"""
                UPDATE approvals SET decision=\(decision.rawValue),approver_id=\(principal),
                    decided_at=to_timestamp(\(Double(now/1_000)))+\(now%1_000)*interval '1 millisecond',version=version+1
                WHERE actor_id=\(record.binding.actorID) AND id=\(record.id) AND version=\(record.version) AND decision='pending' RETURNING id
                """)
            guard rows.count == 1 else { throw ApprovalError.conflict }
            return next
        }
    }
    private func serverNow(_ connection: PostgresConnection) async throws -> Int64 {
        let rows = try await BoundedPostgresQuery.rows(connection,"SELECT floor(extract(epoch FROM clock_timestamp())*1000)::bigint")
        guard let row = rows.first else { throw ApprovalError.unavailable };return try row.decode(Int64.self)
    }
    private struct Row: Decodable {
        let id: UUID, actor_id: UUID, run_id: UUID, ledger_id: UUID
        let command_hash: String, approval_digest: String
        let decision: ApprovalDecision, approver_id: UUID?
        let requested_ms: Int64, expires_ms: Int64, decided_ms: Int64?, version: Int64
    }
    private func select(_ connection: PostgresConnection, actorID: UUID, id: UUID, lock: Bool) async throws -> ApprovalRecord {
        let query: PostgresQuery = lock ? """
            SELECT row_to_json(r)::text FROM (SELECT id,actor_id,run_id,ledger_id,encode(command_hash,'hex') AS command_hash,
                encode(approval_digest,'hex') AS approval_digest,decision,approver_id,floor(extract(epoch FROM requested_at)*1000)::bigint AS requested_ms,
                floor(extract(epoch FROM expires_at)*1000)::bigint AS expires_ms,floor(extract(epoch FROM decided_at)*1000)::bigint AS decided_ms,version
                FROM approvals WHERE actor_id=\(actorID) AND id=\(id) FOR UPDATE) AS r
            """ : """
            SELECT row_to_json(r)::text FROM (SELECT id,actor_id,run_id,ledger_id,encode(command_hash,'hex') AS command_hash,
                encode(approval_digest,'hex') AS approval_digest,decision,approver_id,floor(extract(epoch FROM requested_at)*1000)::bigint AS requested_ms,
                floor(extract(epoch FROM expires_at)*1000)::bigint AS expires_ms,floor(extract(epoch FROM decided_at)*1000)::bigint AS decided_ms,version
                FROM approvals WHERE actor_id=\(actorID) AND id=\(id)) AS r
            """
        let rows = try await BoundedPostgresQuery.rows(connection,query)
        guard let row = rows.first else { throw ApprovalError.notFound }
        do {
            let text = try row.decode(String.self)
            guard text.utf8.count <= 4_096 else { throw ApprovalError.corruptRecord }
            let value = try JSONDecoder().decode(Row.self,from:Data(text.utf8)),hash = try decodeHex(value.command_hash)
            guard value.id == id,value.actor_id == actorID else { throw ApprovalError.corruptRecord }
            let binding = try ApprovalBinding(actorID:actorID,runID:value.run_id,ledgerID:value.ledger_id,commandHash:hash)
            let record = try ApprovalRecord(id:id,binding:binding,requestedAtMilliseconds:value.requested_ms,expiresAtMilliseconds:value.expires_ms,
                decision:value.decision,approverID:value.approver_id,decidedAtMilliseconds:value.decided_ms,version:value.version)
            guard try decodeHex(value.approval_digest) == record.digest else { throw ApprovalError.corruptRecord }
            return record
        } catch { throw ApprovalError.corruptRecord }
    }
    private func decodeHex(_ text: String) throws -> Data {
        let bytes = Array(text.utf8)
        guard bytes.count == 64 else { throw ApprovalError.corruptRecord }
        var result = Data()
        for index in stride(from:0,to:64,by:2) {
            guard let byte = UInt8(String(decoding:bytes[index...index+1],as:UTF8.self),radix:16) else { throw ApprovalError.corruptRecord }
            result.append(byte)
        }
        return result
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
        guard deadline > now, deadline <= now.advanced(by: .seconds(5)) else { throw ApprovalError.unavailable }
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
                group.addTask { try await Task.sleep(until: deadline); throw ApprovalError.unavailable }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch {
            try Task.checkCancellation()
            if let error = error as? ApprovalError { throw error }
            if let error = error as? PSQLError {
                switch error.serverInfo?[.sqlState] {
                case "23505": throw ApprovalError.conflict
                case "23503", "P0002": throw ApprovalError.notFound
                case "40001", "55000": throw ApprovalError.conflict
                default: break
                }
            }
            throw ApprovalError.unavailable
        }
    }
}
