import Foundation
import SquidraDomain
import SquidraMemory
import XCTest

private actor ImportStore: ConsolidationStore {
    var value: ConsolidationArchive?
    var writes = 0
    func load(id: UUID, deadline: ContinuousClock.Instant) -> ConsolidationArchive? { value?.id == id ? value : nil }
    func save(_ archive: ConsolidationArchive, deadline: ContinuousClock.Instant) throws {
        if let current = value {
            if try current.encoded() == archive.encoded() { return }
            guard try archive.predecessor() == current.encoded() else { throw ConsolidationStoreError.conflict }
        } else { guard archive.version == 0 else { throw ConsolidationStoreError.conflict } }
        value = archive; writes += 1
    }
}
final class ConsolidationImportTests: XCTestCase, @unchecked Sendable {
    let actor = UUID(), journal = UUID(), batch = UUID(), memory = UUID(), subject = UUID(), source = UUID()
    func input() -> [String: Any] {
        ["schemaVersion": "1", "journalId": journal.uuidString, "batchId": batch.uuidString,
         "records": [["id": memory.uuidString, "subjectId": subject.uuidString, "sourceIds": [source.uuidString], "text": "red blue"]],
         "predicates": [["name": "color", "critical": true]],
         "candidates": [["subjectId": subject.uuidString, "predicate": "color", "value": "red", "validFrom": "2026-01-01T00:00:00Z", "validUntil": NSNull(), "quotations": [memory.uuidString: "red"]]]]
    }
    func parse(_ object: [String: Any]) throws -> ConsolidationBatchImport {
        try ConsolidationBatchImport(data: JSONSerialization.data(withJSONObject: object), actorID: actor)
    }
    func testClosedInputRejectsApprovalsIdentityClassificationAndDuplicateKeys() throws {
        for key in ["actorId", "review", "commands", "approved"] {
            var object = input(); object[key] = "forged"
            XCTAssertThrowsError(try parse(object))
        }
        var object = input(), records = try XCTUnwrap(object["records"] as? [[String: Any]])
        records[0]["sensitivity"] = "modelAllowed"; object["records"] = records
        XCTAssertThrowsError(try parse(object))
        var wrongType = input(); wrongType["predicates"] = [["name": "color", "critical": 1]]
        XCTAssertThrowsError(try parse(wrongType))
        let bytes = try JSONSerialization.data(withJSONObject: input()), text = String(decoding: bytes, as: UTF8.self)
        for suffix in [",\"schemaVersion\":\"1\"}", #","schema\u0056ersion":"1"}"#] {
            XCTAssertThrowsError(try ConsolidationBatchImport(data: Data((text.dropLast() + suffix).utf8), actorID: actor))
        }
        XCTAssertThrowsError(try ConsolidationBatchImport(data: Data(repeating: 32, count: 1_048_577), actorID: actor))
    }
    func testInvalidEvidenceIsRejectedBeforeGenesisIsWritten() async throws {
        let store = ImportStore()
        var object = input(), candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
        candidates[0]["quotations"] = [memory.uuidString: "fabricated"]
        object["candidates"] = candidates
        let invalid = try parse(object)
        do { _ = try await invalid.apply(to: store); XCTFail() } catch { XCTAssertEqual(error as? ConsolidationError, .invalidSource) }
        let writes = await store.writes; XCTAssertEqual(writes, 0)
    }
    func testExactRetryPreservesReviewWhileChangedBatchAndSourcesConflict() async throws {
        let store = ImportStore(), batch = try parse(input())
        let first = try await batch.apply(to: store), again = try await batch.apply(to: store)
        XCTAssertEqual(first.proposals.map(\.id), again.proposals.map(\.id)); XCTAssertEqual(again.archive.version, 1)
        var reviewed = again.archive
        _ = try await reviewed.review(id: first.proposals[0].id, expectedVersion: 0, authenticatedActorID: actor, reviewerID: actor, approve: true, at: UTCInstant(secondsSince1970: 1_800_000_000))
        try await store.save(reviewed, deadline: .now.advanced(by: .seconds(4)))
        let retained = try await batch.apply(to: store)
        XCTAssertEqual(retained.archive.version, 2); XCTAssertEqual(retained.proposals[0].state, .approved)
        let workspace = try await retained.archive.workspace(), original = await workspace.original(id: memory)
        XCTAssertEqual(original?.sensitivity, .privateOnly)
        var changed = input(), candidates = try XCTUnwrap(changed["candidates"] as? [[String: Any]])
        candidates[0]["value"] = "blue"; changed["candidates"] = candidates
        do { _ = try await parse(changed).apply(to: store); XCTFail() } catch { XCTAssertEqual(error as? ConsolidationError, .conflict) }
        var changedSource = input(), records = try XCTUnwrap(changedSource["records"] as? [[String: Any]])
        records[0]["text"] = "red blue changed"; changedSource["records"] = records
        do { _ = try await parse(changedSource).apply(to: store); XCTFail() } catch { XCTAssertEqual(error as? ConsolidationError, .conflict) }
        let writes = await store.writes; XCTAssertEqual(writes, 3)
    }
    func testConcurrentIdenticalImportsConvergeOnOneBatch() async throws {
        let store = ImportStore(), batch = try parse(input())
        async let first = batch.apply(to: store)
        async let second = batch.apply(to: store)
        let results = try await [first, second]
        XCTAssertEqual(results[0].proposals.map(\.id), results[1].proposals.map(\.id))
        let writes = await store.writes; XCTAssertEqual(writes, 2)
    }
}
