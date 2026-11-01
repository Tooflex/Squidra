import Foundation
import Hummingbird
import HummingbirdTesting
import SquidraDomain
import SquidraMemory
import SquidraPostgres
import XCTest
@testable import SquidraServer

private struct FailingConsolidationSave: ConsolidationStore {
    let base: PostgresConsolidationStore
    func save(_ archive: ConsolidationArchive, deadline: ContinuousClock.Instant) async throws { throw ConsolidationStoreError.unavailable }
    func load(id: UUID, deadline: ContinuousClock.Instant) async throws -> ConsolidationArchive? { try await base.load(id: id, deadline: deadline) }
}
final class ConsolidationRouteTests: XCTestCase, @unchecked Sendable {
    static let token = String(repeating: "a", count: 64)
    static func body(journal: Int = 1, proposal: Int = 0, decision: String = "approved") -> String {
        "{\"schemaVersion\":\"1\",\"journalVersion\":\"\(journal)\",\"proposalVersion\":\"\(proposal)\",\"decision\":\"\(decision)\"}"
    }
    static func seed(store: PostgresConsolidationStore, conflict: Bool = false) async throws -> (ConsolidationArchive, UUID, MemoryRecord) {
        let record = try MemoryRecord(actorID: store.actorID, subjectID: UUID(), sourceIDs: [UUID()], sensitivity: .privateOnly,
                                      text: "The key was red. The key was blue. <script>approve()</script>")
        var archive = try ConsolidationArchive(actorID: store.actorID, records: [record], predicates: [FactPredicate(name: "key.color", critical: true)])
        try await store.save(archive, deadline: .now.advanced(by: .seconds(4)))
        let interval = try InstantInterval(start: UTCInstant(secondsSince1970: 0), end: nil)
        var candidates = [try FactCandidate(subjectID: record.subjectID, predicate: "key.color", value: "red", validTime: interval, quotations: [record.id: "The key was red."])]
        if conflict { candidates.append(try FactCandidate(subjectID: record.subjectID, predicate: "key.color", value: "blue", validTime: interval, quotations: [record.id: "The key was blue."])) }
        let proposal = try await archive.propose(batchID: UUID(), candidates: candidates)[0]
        try await store.save(archive, deadline: .now.advanced(by: .seconds(4)))
        return (archive, proposal.id, record)
    }
    func testLivePreviewReviewAndRestartPreserveEvidenceAndAuthenticatedIdentity() async throws {
        try await RunHTTPTestSupport.withClients { client, second in
            let actor = UUID(), store = PostgresConsolidationStore(client: client, actorID: actor)
            let (archive, proposalID, record) = try await Self.seed(store: store)
            let config = try RunHTTPTestSupport.configuration(actor: actor, token: Self.token)
            let index = "/api/v1/consolidations/" + archive.id.uuidString, path = index + "/proposals/" + proposalID.uuidString
            try await ServerComposition.live(configuration: config).test(.live) { http in
                try await http.execute(uri: path, method: .get) { XCTAssertEqual($0.status, .unauthorized) }
                try await http.execute(uri: path + "/decision", method: .post, body: .init(string: Self.body())) { XCTAssertEqual($0.status, .unauthorized) }
                try await http.execute(uri: index, method: .get, headers: [.authorization: "Bearer " + Self.token]) { response in
                    XCTAssertEqual(response.status, .ok); XCTAssertEqual(response.headers[.cacheControl], "no-store")
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                    XCTAssertEqual((json["proposals"] as? [[String: Any]])?.count, 1)
                }
                try await http.execute(uri: path, method: .get, headers: [.authorization: "Bearer " + Self.token]) { response in
                    XCTAssertEqual(response.status, .ok)
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                    XCTAssertEqual((json["proposal"] as? [String: Any])?["critical"] as? Bool, true)
                    XCTAssertEqual(json["value"] as? String, "red")
                    XCTAssertEqual(json["validFrom"] as? String, "1970-01-01T00:00:00.000000Z")
                    XCTAssertEqual((json["evidence"] as? [[String: Any]])?.first?["originalText"] as? String, record.text)
                }
                try await http.execute(uri: path + "/decision", method: .post, headers: [.authorization: "Bearer " + Self.token, .contentType: "application/json"], body: .init(string: Self.body())) { response in
                    XCTAssertEqual(response.status, .ok)
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                    XCTAssertEqual(json["reviewerId"] as? String, actor.uuidString)
                    XCTAssertEqual((json["proposal"] as? [String: Any])?["state"] as? String, "approved")
                }
                try await http.execute(uri: path + "/decision", method: .post, headers: [.authorization: "Bearer " + Self.token, .contentType: "application/json"], body: .init(string: Self.body())) { XCTAssertEqual($0.status, .conflict) }
            }
            // Recreate the normal server and independently reload its durable decision.
            try await ServerComposition.live(configuration: config).test(.live) { http in
                try await http.execute(uri: path, method: .get, headers: [.authorization: "Bearer " + Self.token]) { response in
                    XCTAssertEqual(response.status, .ok)
                    XCTAssertTrue(String(buffer: response.body).contains("\"state\":\"approved\""))
                }
            }
            let stored = try await PostgresConsolidationStore(client: second, actorID: actor).load(id: archive.id, deadline: .now.advanced(by: .seconds(4)))
            let loaded = try XCTUnwrap(stored), workspace = try await loaded.workspace()
            XCTAssertEqual(loaded.version, 2)
            let promoted = try await workspace.promotedMemory(id: proposalID)
            XCTAssertEqual(promoted.sourceIDs, record.sourceIDs); XCTAssertEqual(promoted.sensitivity, .privateOnly)
            let otherConfig = try RunHTTPTestSupport.configuration(actor: UUID(), token: Self.token)
            try await ServerComposition.live(configuration: otherConfig).test(.live) { http in
                try await http.execute(uri: path, method: .get, headers: [.authorization: "Bearer " + Self.token]) { XCTAssertEqual($0.status, .notFound) }
                try await http.execute(uri: path + "/decision", method: .post, headers: [.authorization: "Bearer " + Self.token, .contentType: "application/json"], body: .init(string: Self.body())) { XCTAssertEqual($0.status, .notFound) }
            }
        }
    }
    func testClosedDecisionGrammarStaleVersionsRejectionAndConflict() async throws {
        try await RunHTTPTestSupport.withClients { client, _ in
            let actor = UUID(), store = PostgresConsolidationStore(client: client, actorID: actor)
            let (archive, id, _) = try await Self.seed(store: store)
            let (conflicted, conflictID, _) = try await Self.seed(store: store, conflict: true)
            let config = try RunHTTPTestSupport.configuration(actor: actor, token: Self.token)
            let path = "/api/v1/consolidations/\(archive.id)/proposals/\(id)/decision"
            try await ServerComposition.live(configuration: config).test(.live) { http in
                let valid = Self.body()
                let malformed = ["[]", "\u{00a0}" + valid, valid.dropLast() + ",\"actorId\":\"fake\"}", valid.dropLast() + ",\"decision\":\"rejected\"}",
                                 valid.replacingOccurrences(of: "\"1\"", with: "1"), valid.replacingOccurrences(of: "proposalVersion", with: #"proposal\u0056ersion"#),
                                 valid.replacingOccurrences(of: "\"0\"", with: "\"00\""), Self.body(decision: "allow"), Self.body(journal: 513)]
                for value in malformed {
                    try await http.execute(uri: path, method: .post, headers: [.authorization: "Bearer " + Self.token, .contentType: "application/json"], body: .init(string: value)) { XCTAssertEqual($0.status, .badRequest) }
                }
                for value in [Self.body(journal: 0), Self.body(proposal: 1)] {
                    try await http.execute(uri: path, method: .post, headers: [.authorization: "Bearer " + Self.token, .contentType: "application/json"], body: .init(string: value)) { XCTAssertEqual($0.status, .conflict) }
                }
                try await http.execute(uri: path, method: .post, headers: [.authorization: "Bearer " + Self.token], body: .init(string: valid)) { XCTAssertEqual($0.status, .badRequest) }
                try await http.execute(uri: path, method: .post, headers: [.authorization: "Bearer " + Self.token, .contentType: "application/json"], body: .init(string: Self.body(decision: "rejected"))) { XCTAssertEqual($0.status, .ok) }
                let conflictPath = "/api/v1/consolidations/\(conflicted.id)/proposals/\(conflictID)/decision"
                try await http.execute(uri: conflictPath, method: .post, headers: [.authorization: "Bearer " + Self.token, .contentType: "application/json"], body: .init(string: Self.body(proposal: 1))) { XCTAssertEqual($0.status, .conflict) }
            }
            let persisted = try await store.load(id: archive.id, deadline: .now.advanced(by: .seconds(4)))
            let workspace = try await XCTUnwrap(persisted).workspace(), proposal = await workspace.proposal(id: id)
            XCTAssertEqual(proposal?.state, .rejected)
            do { _ = try await workspace.promotedMemory(id: id); XCTFail() } catch {}
        }
    }
    func testSaveFailureNeverReportsSuccessfulReview() async throws {
        try await RunHTTPTestSupport.withClients { client, _ in
            let actor = UUID(), store = PostgresConsolidationStore(client: client, actorID: actor)
            let (archive, id, _) = try await Self.seed(store: store)
            let config = try RunHTTPTestSupport.configuration(actor: actor, token: Self.token)
            try await ServerComposition.application(configuration: config, readiness: { .ready }, consolidation: FailingConsolidationSave(base: store)).test(.router) { http in
                try await http.execute(uri: "/api/v1/consolidations/\(archive.id)/proposals/\(id)/decision", method: .post,
                                       headers: [.authorization: "Bearer " + Self.token, .contentType: "application/json"], body: .init(string: Self.body())) { response in
                    XCTAssertEqual(response.status, .serviceUnavailable)
                    XCTAssertFalse(String(buffer: response.body).contains("red"))
                }
            }
            let persisted = try await store.load(id: archive.id, deadline: .now.advanced(by: .seconds(4)))
            XCTAssertEqual(persisted?.version, 1)
        }
    }
}
