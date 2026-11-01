import Foundation
import PostgresNIO
import SquidraAgentRuntime

/// The local handle must remain held until the host joins every worker.
public struct PostgresReadRunOwnershipStore: ReadRunOwnershipStore {
    private let client: PostgresClient
    private let ownership: LocalRunOwnership
    public init(client: PostgresClient,ownership: LocalRunOwnership) { self.client = client;self.ownership = ownership }
    public func bind(deadline: ContinuousClock.Instant) async throws {
        guard ownership.isHeld else { throw ReadRunTaskError.invalidState }
        try await bounded(deadline) { c in try await bind(c) }
        guard ownership.isHeld else { throw ReadRunTaskError.invalidState }
    }
    private func bind(_ c: PostgresConnection) async throws {
        let actor = ownership.actorID,domain = ownership.domainID,file = ownership.fileID
        _ = try await BoundedPostgresQuery.rows(c,"INSERT INTO read_run_local_domains(actor_id,domain_id,file_id) VALUES(\(actor),\(domain),\(file)) ON CONFLICT(actor_id) DO NOTHING")
        let rows = try await BoundedPostgresQuery.rows(c,"SELECT domain_id,file_id FROM read_run_local_domains WHERE actor_id=\(actor)")
        guard let row = rows.first else { throw ReadRunTaskError.conflict }
        let (storedDomain,storedFile) = try row.decode((UUID,String).self)
        guard storedDomain == domain,storedFile == file else { throw ReadRunTaskError.conflict }
    }
    public func register(runID: UUID,deadline: ContinuousClock.Instant) async throws {
        guard ownership.isHeld else { throw ReadRunTaskError.invalidState }
        let actor = ownership.actorID,domain = ownership.domainID,file = ownership.fileID,owner = ownership.ownerID
        try await bounded(deadline) { c in
            try await bind(c)
            _ = try await BoundedPostgresQuery.rows(c,"""
                WITH checked AS MATERIALIZED (
                    SELECT t.run_id FROM read_run_tasks t JOIN run_event_streams s ON s.actor_id=t.actor_id AND s.run_id=t.run_id
                    WHERE t.actor_id=\(actor) AND t.run_id=\(runID) AND s.publication_phase='unmanaged'
                        AND s.expires_at>clock_timestamp() FOR SHARE OF s
                )
                INSERT INTO read_run_owners(actor_id,run_id,domain_id,file_id,owner_id)
                SELECT \(actor),run_id,\(domain),\(file),\(owner) FROM checked
                ON CONFLICT(actor_id,run_id) DO NOTHING
                """)
            let rows = try await BoundedPostgresQuery.rows(c,"SELECT domain_id,file_id,owner_id FROM read_run_owners WHERE actor_id=\(actor) AND run_id=\(runID)")
            guard let row = rows.first else { throw ReadRunTaskError.conflict }
            let (d,f,o) = try row.decode((UUID,String,UUID).self)
            guard d == domain,f == file,o == owner else { throw ReadRunTaskError.conflict }
        }
        guard ownership.isHeld else { throw ReadRunTaskError.invalidState }
    }
    /// Bounded candidates only; selection is not a publication or dispatch claim.
    public func previousRuns(limit: Int = 8,deadline: ContinuousClock.Instant) async throws -> [StoredReadRunOwner] {
        guard ownership.isHeld,(1...8).contains(limit) else { throw ReadRunTaskError.invalidState }
        let actor = ownership.actorID,domain = ownership.domainID,file = ownership.fileID,owner = ownership.ownerID
        let selected = try await bounded(deadline) { c in
            try await bind(c)
            let rows = try await BoundedPostgresQuery.rows(c,"""
                SELECT o.run_id,o.owner_id FROM read_run_owners o
                JOIN run_event_streams s ON s.actor_id=o.actor_id AND s.run_id=o.run_id
                WHERE o.actor_id=\(actor) AND o.domain_id=\(domain) AND o.file_id=\(file) AND o.owner_id<>\(owner)
                    AND s.publication_phase='running' AND s.expires_at>clock_timestamp()
                ORDER BY o.run_id LIMIT \(limit)
                """)
            return try rows.map { row in
                let (run,previousOwner) = try row.decode((UUID,UUID).self)
                return StoredReadRunOwner(actorID:actor,runID:run,ownerID:previousOwner)
            }
        }
        guard ownership.isHeld else { throw ReadRunTaskError.invalidState };return selected
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
