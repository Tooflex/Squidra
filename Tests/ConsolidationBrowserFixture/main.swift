import Foundation
import PostgresNIO
import SquidraDomain
import SquidraMemory
import SquidraPostgres

private struct Manifest: Codable {
    let actor: UUID, journal: UUID, proposal: UUID, rejectedJournal: UUID, rejectedProposal: UUID
    let conflictedJournal: UUID, conflictedProposal: UUID, memory: UUID, source: UUID
}
private enum Failure: Error { case invalid }
private func run() async throws {
    let env = ProcessInfo.processInfo.environment, args = Array(CommandLine.arguments.dropFirst())
    guard env["SQUIDRA_BROWSER_FIXTURE"] == "1", args.count == 2, ["seed", "verify"].contains(args[0]),
          let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init), let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw Failure.invalid }
    let path = URL(fileURLWithPath: args[1])
    let client = try LocalDatabaseConfiguration(port: port, username: "squidra", password: password, database: "squidra").makeClient()
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await client.run() }; defer { group.cancelAll() }
        if args[0] == "seed" {
            let actor = UUID(), source = UUID(), record = try MemoryRecord(actorID: actor, subjectID: UUID(), sourceIDs: [source], sensitivity: .privateOnly,
                text: "The key was red. The key was blue. <script>window.compromised=true</script>")
            let store = PostgresConsolidationStore(client: client, actorID: actor)
            var journals: [(UUID, UUID)] = []
            for index in 0..<3 {
                var archive = try ConsolidationArchive(actorID: actor, records: [record], predicates: [FactPredicate(name: "key.color", critical: true)])
                try await store.save(archive, deadline: .now.advanced(by: .seconds(4)))
                let period = try InstantInterval(start: UTCInstant(secondsSince1970: 0), end: nil)
                var candidates = [try FactCandidate(subjectID: record.subjectID, predicate: "key.color", value: "red", validTime: period, quotations: [record.id: "The key was red."])]
                if index == 2 { candidates.append(try FactCandidate(subjectID: record.subjectID, predicate: "key.color", value: "blue", validTime: period, quotations: [record.id: "The key was blue."])) }
                let proposal = try await archive.propose(batchID: UUID(), candidates: candidates)[0]
                try await store.save(archive, deadline: .now.advanced(by: .seconds(4))); journals.append((archive.id, proposal.id))
            }
            let manifest = Manifest(actor: actor, journal: journals[0].0, proposal: journals[0].1, rejectedJournal: journals[1].0, rejectedProposal: journals[1].1,
                                    conflictedJournal: journals[2].0, conflictedProposal: journals[2].1, memory: record.id, source: source)
            try JSONEncoder().encode(manifest).write(to: path, options: .atomic)
        } else {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: path))
            let store = PostgresConsolidationStore(client: client, actorID: manifest.actor)
            var snapshots: [String] = []
            for (journalID, proposalID, state) in [(manifest.journal, manifest.proposal, FactProposalState.approved),
                                                  (manifest.rejectedJournal, manifest.rejectedProposal, .rejected),
                                                  (manifest.conflictedJournal, manifest.conflictedProposal, .conflicted)] {
                guard let archive = try await store.load(id: journalID, deadline: .now.advanced(by: .seconds(4))) else { throw Failure.invalid }
                let workspace = try await archive.workspace()
                guard let proposal = await workspace.proposal(id: proposalID), proposal.state == state,
                      let original = await workspace.original(id: manifest.memory), original.sourceIDs == [manifest.source],
                      original.text == "The key was red. The key was blue. <script>window.compromised=true</script>" else { throw Failure.invalid }
                if state == .conflicted {
                    guard archive.version == 1, proposal.review == nil else { throw Failure.invalid }
                } else {
                    guard archive.version == 2, proposal.review?.reviewerID == manifest.actor else { throw Failure.invalid }
                }
                if state == .approved {
                    let memory = try await workspace.promotedMemory(id: proposalID)
                    guard memory.sourceIDs == [manifest.source], memory.sensitivity == .privateOnly else { throw Failure.invalid }
                } else {
                    do { _ = try await workspace.promotedMemory(id: proposalID); throw Failure.invalid }
                    catch ConsolidationError.forbidden {} // No publication from rejected/contradictory evidence.
                }
                snapshots.append(try archive.encoded())
            }
            let snapshotPath = path.appendingPathExtension("verified.json"), bytes = try JSONEncoder().encode(snapshots)
            if FileManager.default.fileExists(atPath: snapshotPath.path) {
                guard try Data(contentsOf: snapshotPath) == bytes else { throw Failure.invalid }
            } else { try bytes.write(to: snapshotPath, options: .atomic) }
        }
    }
}
do { try await run(); print("CONSOLIDATION_BROWSER_FIXTURE_OK") }
catch { FileHandle.standardError.write(Data("Consolidation browser fixture failed.\n".utf8)); exit(1) }
