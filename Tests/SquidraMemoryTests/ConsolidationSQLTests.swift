import Foundation
import PostgresNIO
import SquidraDomain
import SquidraMemory
import SquidraPostgres
import XCTest

final class ConsolidationSQLTests: XCTestCase, @unchecked Sendable {
    func fixtures() throws -> (ConsolidationArchive, MemoryRecord, FactCandidate) {
        let actorID = UUID(), subjectID = UUID()
        let record = try MemoryRecord(actorID: actorID, subjectID: subjectID, sourceIDs: [UUID()], sensitivity: .privateOnly, text: "The key was red. The key was blue.")
        let archive = try ConsolidationArchive(actorID: actorID, records: [record], predicates: [FactPredicate(name: "key.color", critical: true)])
        return (archive, record, try candidate(record, "red"))
    }
    func candidate(_ record: MemoryRecord, _ value: String) throws -> FactCandidate {
        try FactCandidate(subjectID: record.subjectID, predicate: "key.color", value: value,
                          validTime: InstantInterval(start: UTCInstant(secondsSince1970: 0), end: nil), quotations: [record.id: record.text])
    }
    func client() throws -> PostgresClient {
        let env = ProcessInfo.processInfo.environment
        return try LocalDatabaseConfiguration(port: XCTUnwrap(env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init)), username: "squidra",
                                              password: XCTUnwrap(env["SQUIDRA_TEST_DB_PASSWORD"]), database: "squidra").makeClient()
    }
    func saveResult(_ store: PostgresConsolidationStore, _ archive: ConsolidationArchive) async throws -> Bool {
        do { try await store.save(archive, deadline: .now.advanced(by: .seconds(4))); return true }
        catch ConsolidationStoreError.conflict { return false }
    }
    func testReloadReviewConcurrentCASLateConflictAndImmutableOriginals() async throws {
        var (archive, record, input) = try fixtures()
        let first = try client(), second = try client()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await first.run() }; group.addTask { await second.run() }; defer { group.cancelAll() }
            let store = PostgresConsolidationStore(client: first, actorID: record.actorID)
            let restarted = PostgresConsolidationStore(client: second, actorID: record.actorID)
            try await store.save(archive, deadline: .now.advanced(by: .seconds(4)))
            let batch = UUID(), proposal = try await archive.propose(batchID: batch, candidates: [input])[0]
            try await store.save(archive, deadline: .now.advanced(by: .seconds(4)))
            // Retry committed data as if its acknowledgement had been lost.
            try await restarted.save(archive, deadline: .now.advanced(by: .seconds(4)))
            let loaded = try await restarted.load(id: archive.id, deadline: .now.advanced(by: .seconds(4)))
            var restored = try XCTUnwrap(loaded)
            XCTAssertEqual(try restored.encoded(), try archive.encoded())
            let replay = try await restored.propose(batchID: batch, candidates: [input])
            XCTAssertEqual(replay[0].id, proposal.id); XCTAssertEqual(restored.version, 1)
            let reviewer = UUID()
            _ = try await restored.review(id: proposal.id, expectedVersion: 0, authenticatedActorID: record.actorID,
                                          reviewerID: reviewer, approve: true, at: UTCInstant(secondsSince1970: 100))
            try await restarted.save(restored, deadline: .now.advanced(by: .seconds(4)))
            let reviewed = try await store.load(id: archive.id, deadline: .now.advanced(by: .seconds(4)))
            let reviewedArchive = try XCTUnwrap(reviewed), workspace = try await reviewedArchive.workspace()
            let memory = try await workspace.promotedMemory(id: proposal.id)
            XCTAssertEqual(memory.sourceIDs, record.sourceIDs); XCTAssertEqual(memory.sensitivity, .privateOnly)
            let review = await workspace.proposal(id: proposal.id)
            XCTAssertEqual(review?.review?.reviewerID, reviewer)
            var left = reviewedArchive, right = reviewedArchive
            _ = try await left.propose(batchID: UUID(), candidates: [candidate(record, "blue")])
            _ = try await right.propose(batchID: UUID(), candidates: [candidate(record, "green")])
            async let a = saveResult(store, left)
            async let b = saveResult(restarted, right)
            let winners = try await [a, b]
            XCTAssertEqual(winners.filter { $0 }.count, 1)
            let final = try await restarted.load(id: archive.id, deadline: .now.advanced(by: .seconds(4)))
            let finalArchive = try XCTUnwrap(final), finalWorkspace = try await finalArchive.workspace()
            XCTAssertEqual(finalArchive.version, 3)
            let conflicted = await finalWorkspace.proposal(id: proposal.id)
            XCTAssertEqual(conflicted?.state, .conflicted); XCTAssertEqual(conflicted?.review?.reviewerID, reviewer)
            do { _ = try await finalWorkspace.promotedMemory(id: proposal.id); XCTFail() } catch { XCTAssertEqual(error as? ConsolidationError, .forbidden) }
            let original = await finalWorkspace.original(id: record.id)
            XCTAssertEqual(original?.text, record.text); XCTAssertEqual(original?.sourceIDs, record.sourceIDs)
            let foreign = PostgresConsolidationStore(client: second, actorID: UUID())
            let foreignRead = try await foreign.load(id: archive.id, deadline: .now.advanced(by: .seconds(4)))
            XCTAssertNil(foreignRead)
            do { try await foreign.save(finalArchive, deadline: .now.advanced(by: .seconds(4))); XCTFail() }
            catch { XCTAssertEqual(error as? ConsolidationStoreError, .invalidArchive) }
            do { _ = try await store.load(id: archive.id, deadline: .now); XCTFail() }
            catch { XCTAssertEqual(error as? ConsolidationStoreError, .timeout) }
        }
    }
    func testSQLRejectsHistoryDeletionRewritingMissingFieldsAndSkippedGenesis() async throws {
        var (archive, record, input) = try fixtures()
        let client = try client()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }; defer { group.cancelAll() }
            let store = PostgresConsolidationStore(client: client, actorID: record.actorID)
            try await store.save(archive, deadline: .now.advanced(by: .seconds(4)))
            let id = archive.id, actorID = archive.actorID
            for query: PostgresQuery in [
                "DELETE FROM consolidation_journals WHERE id=\(id) AND actor_id=\(actorID)",
                "TRUNCATE consolidation_journals",
                "UPDATE consolidation_journals SET version=version+1 WHERE id=\(id) AND actor_id=\(actorID)",
                "INSERT INTO consolidation_journals(actor_id,id,version,archive) VALUES(\(actorID),\(UUID()),0,'{}')"
            ] {
                do { _ = try await client.query(query).collect(); XCTFail("History guard accepted mutation") } catch is PSQLError {} catch { throw error }
            }
            _ = try await archive.propose(batchID: UUID(), candidates: [input])
            // Cannot create an already-reviewed/non-genesis history as a new row.
            let other = try ConsolidationArchive(actorID: record.actorID, records: [record], predicates: [FactPredicate(name: "key.color", critical: true)])
            var skipped = other; _ = try await skipped.propose(batchID: UUID(), candidates: [input])
            do { try await store.save(skipped, deadline: .now.advanced(by: .seconds(4))); XCTFail() }
            catch { XCTAssertEqual(error as? ConsolidationStoreError, .conflict) }
            let skippedText = try skipped.encoded(), skippedID = skipped.id
            do {
                _ = try await client.query("INSERT INTO consolidation_journals(actor_id,id,version,archive) VALUES(\(actorID),\(skippedID),1,\(skippedText))").collect()
                XCTFail("SQL accepted non-genesis insertion")
            } catch is PSQLError {} catch { throw error }
            // Even a structurally valid next revision cannot replace originals.
            let rewritten = try archive.encoded().replacingOccurrences(of: record.text, with: "Rewritten original")
            do {
                _ = try await client.query("UPDATE consolidation_journals SET version=1,archive=\(rewritten) WHERE actor_id=\(actorID) AND id=\(id)").collect()
                XCTFail("SQL accepted changed source history")
            } catch is PSQLError {} catch { throw error }
            try await store.save(archive, deadline: .now.advanced(by: .seconds(4)))
            let read = try await store.load(id: id, deadline: .now.advanced(by: .seconds(4)))
            XCTAssertEqual(try read?.encoded(), try archive.encoded())
        }
    }
    func testCanonicalArchiveRejectsInjectedStatusAndForgedCitations() async throws {
        var (archive, record, input) = try fixtures()
        _ = try await archive.propose(batchID: UUID(), candidates: [input])
        let text = try archive.encoded()
        let decoded = try await ConsolidationArchive.decode(text)
        XCTAssertEqual(try decoded.encoded(), text)
        for invalid in [text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
                        text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"approved\":true,\"schemaVersion\":1"),
                        text.replacingOccurrences(of: "\"quotes\":{\"" + record.id.uuidString, with: "\"quotes\":{\"" + UUID().uuidString),
                        text + " "] {
            do { _ = try await ConsolidationArchive.decode(invalid); XCTFail("Invalid archive accepted") }
            catch { XCTAssertEqual(error as? ConsolidationStoreError, .invalidArchive) }
        }
    }
}
