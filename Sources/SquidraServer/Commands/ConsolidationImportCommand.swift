import Foundation
import SquidraMemory
import SquidraPostgres
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum ConsolidationImportCommand {
    static func run(configuration: ServerConfiguration, path: String) async throws -> Data {
        guard !path.isEmpty, !path.contains("\0"), path.utf8.count <= 4096 else { throw ConsolidationError.invalidInput }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ConsolidationError.invalidInput }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= 1_048_576,
              let data = try handle.read(upToCount: 1_048_577), data.count <= 1_048_576, data.count == Int(info.st_size) else { throw ConsolidationError.invalidInput }
        let batch = try ConsolidationBatchImport(data: data, actorID: configuration.boundary.actorID)
        let client = configuration.database.makeClient()
        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }; defer { group.cancelAll() }
            let result = try await batch.apply(to: PostgresConsolidationStore(client: client, actorID: configuration.boundary.actorID))
            let summaries = result.proposals.map { proposal in
                let state: String
                switch proposal.state { case .pending: state = "pending"; case .approved: state = "approved"; case .rejected: state = "rejected"; case .conflicted: state = "conflicted" }
                return Proposal(id: proposal.id, version: proposal.version, state: state)
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(Result(journalId: result.archive.id, journalVersion: result.archive.version, proposals: summaries))
        }
    }
    private struct Proposal: Encodable { let id: UUID, version: Int64, state: String }
    private struct Result: Encodable { let schemaVersion = "1"; let journalId: UUID, journalVersion: Int64, proposals: [Proposal] }
}
