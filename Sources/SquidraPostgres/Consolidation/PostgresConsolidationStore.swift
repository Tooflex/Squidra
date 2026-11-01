import Foundation
import PostgresNIO
import SquidraMemory

/// Private actor-bound journal. Every update must append exactly one operation
/// to the exact stored predecessor; a lost acknowledgement can retry identically.
public struct PostgresConsolidationStore: ConsolidationStore {
    private let client: PostgresClient
    public let actorID: UUID
    public init(client: PostgresClient, actorID: UUID) { self.client = client; self.actorID = actorID }
    public func save(_ archive: ConsolidationArchive, deadline: ContinuousClock.Instant) async throws {
        guard archive.actorID == actorID else { throw ConsolidationStoreError.invalidArchive }
        let text = try archive.encoded(), previous = try archive.predecessor(), id = archive.id, version = archive.version
        try await bounded(deadline) { connection in
            if let previous {
                let priorVersion = version - 1
                _ = try await BoundedPostgresQuery.rows(connection, "UPDATE consolidation_journals SET archive=\(text),version=\(version) WHERE actor_id=\(actorID) AND id=\(id) AND version=\(priorVersion) AND archive=\(previous)")
            } else {
                _ = try await BoundedPostgresQuery.rows(connection, "INSERT INTO consolidation_journals(actor_id,id,version,archive) VALUES(\(actorID),\(id),\(version),\(text)) ON CONFLICT(actor_id,id) DO NOTHING")
            }
            let rows = try await BoundedPostgresQuery.rows(connection, "SELECT archive=\(text) AND version=\(version) FROM consolidation_journals WHERE actor_id=\(actorID) AND id=\(id)")
            guard let row = rows.first, try row.decode(Bool.self) else { throw ConsolidationStoreError.conflict }
        }
    }
    public func load(id: UUID, deadline: ContinuousClock.Instant) async throws -> ConsolidationArchive? {
        try await bounded(deadline) { connection in
            let rows = try await BoundedPostgresQuery.rows(connection, "SELECT archive,version FROM consolidation_journals WHERE actor_id=\(actorID) AND id=\(id)")
            guard let row = rows.first else { return nil }
            let (text, version) = try row.decode((String, Int64).self)
            let archive = try await ConsolidationArchive.decode(text)
            guard archive.actorID == actorID, archive.id == id, archive.version == version else { throw ConsolidationStoreError.invalidArchive }
            return archive
        }
    }
    private func bounded<Value: Sendable>(_ deadline: ContinuousClock.Instant,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Value) async throws -> Value {
        let now = ContinuousClock.now
        guard deadline > now, deadline <= now.advanced(by: .seconds(5)) else { throw ConsolidationStoreError.timeout }
        do {
            return try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask {
                    try await client.withConnection(isolation: nil) { connection in
                        try await withTaskCancellationHandler {
                            try Task.checkCancellation(); return try await body(connection)
                        } onCancel: { connection.close().whenFailure { _ in } }
                    }
                }
                group.addTask { try await ContinuousClock().sleep(until: deadline); throw ConsolidationStoreError.timeout }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw ConsolidationStoreError.unavailable }; return value
            }
        } catch is CancellationError { throw Task.isCancelled ? ConsolidationStoreError.cancelled : ConsolidationStoreError.timeout }
        catch let error as ConsolidationStoreError { throw error }
        catch { throw ConsolidationStoreError.unavailable }
    }
}
