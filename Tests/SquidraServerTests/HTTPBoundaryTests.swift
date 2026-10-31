import Foundation
import Hummingbird
import HummingbirdTesting
import SquidraProtocols
import XCTest
@testable import SquidraServer

// SAFETY: XCTest owns instances; there is no mutable test-instance state.
// Follow-up: remove this conformance when the issue runner supports Swift Testing.
final class HTTPBoundaryTests: XCTestCase, @unchecked Sendable {
    private static func credential() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
    private static func app(token: String, actor: UUID, timeout: Duration = .seconds(2)) throws -> some ApplicationProtocol {
        let router = Router(context: BoundaryContext.self)
        router.get("/api/v1/identity") { _, context in context.actorID!.uuidString }
        router.get("/api/v1/actors/:actor") { _, context -> String in
            guard let id = UUID(uuidString: context.parameters.get("actor") ?? "") else { throw HTTPError(.badRequest) }
            try context.requireActor(id)
            return id.uuidString
        }
        router.post("/api/v1/body") { request, _ -> String in
            let body = try await request.body.collect(upTo: 100)
            return String(body.readableBytes)
        }
        router.get("/api/v1/failure") { _, _ -> String in throw HTTPError(.badRequest, message: "secret=must-never-escape") }
        router.get("/api/v1/raw-failure") { _, _ in Response(status: .internalServerError, body: .init(byteBuffer: .init(string: "secret=must-never-escape"))) }
        router.get("/api/v1/slow") { _, _ -> String in
            try await Task.sleep(for: .seconds(60))
            return "should not finish"
        }
        for path in ["/health/live", "/health/ready", "/health", "/ready"] {
            router.get(RouterPath(path)) { _, _ in "{\"status\":\"alive\"}" }
        }
        let config = try BoundaryConfiguration(credential: token, actorID: actor,
            approvedOrigin: "http://localhost:3000", maximumBodyBytes: 8, requestTimeout: timeout)
        return Application(responder: HTTPBoundary(inner: router.buildResponder(), configuration: config))
    }

    func testUnauthenticatedAndInvalidCredentialAreRejected() async throws {
        let token = Self.credential()
        try await Self.app(token: token, actor: UUID()).test(.router) { client in
            for headers: HTTPFields in [[:], [.authorization: "Bearer "+Self.credential()]] {
                try await client.execute(uri: "/api/v1/identity", method: .get, headers: headers) { response in
                    XCTAssertEqual(response.status, .unauthorized)
                    XCTAssertEqual(response.headers[.wwwAuthenticate], "Bearer")
                }
            }
        }
    }

    func testIdentityComesFromHostAndActorScopeIsEnforced() async throws {
        let token = Self.credential(), actor = UUID(), other = UUID()
        try await Self.app(token: token, actor: actor).test(.router) { client in
            try await client.execute(uri: "/api/v1/identity", method: .get, headers: [.authorization: "Bearer "+token]) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), actor.uuidString)
            }
            try await client.execute(uri: "/api/v1/actors/"+other.uuidString, method: .get, headers: [.authorization: "Bearer "+token]) { response in
                XCTAssertEqual(response.status, .forbidden)
            }
            try await client.execute(uri: "/api/v1/identity", method: .get,
                headers: [.authorization: "Bearer "+token, .init("X-Actor-ID")!: other.uuidString]) { response in
                XCTAssertEqual(response.status, .forbidden)
            }
        }
    }

    func testBodyWithoutLengthIsBoundedAndRetained() async throws {
        let token = Self.credential()
        try await Self.app(token: token, actor: UUID()).test(.router) { client in
            for size in [8, 9] {
                try await client.execute(uri: "/api/v1/body", method: .post, headers: [.authorization: "Bearer "+token],
                    body: .init(repeating: 65, count: size)) { response in
                    XCTAssertEqual(response.status, size == 8 ? .ok : .contentTooLarge)
                    if size == 8 { XCTAssertEqual(String(buffer: response.body), "8") }
                }
            }
        }
    }

    func testDeclaredOversizedBodyIsRejected() async throws {
        let token = Self.credential()
        try await Self.app(token: token, actor: UUID()).test(.router) { client in
            try await client.execute(uri: "/api/v1/body", method: .post,
                headers: [.authorization: "Bearer "+token, .contentLength: "999"]) { response in
                XCTAssertEqual(response.status, .contentTooLarge)
            }
        }
    }

    func testErrorsHaveStrictEnvelopeAndHostRequestIDs() async throws {
        let token = Self.credential()
        try await Self.app(token: token, actor: UUID()).test(.router) { client in
            var ids = Set<UUID>()
            for path in ["failure", "raw-failure", "missing"] {
                try await client.execute(uri: "/api/v1/"+path, method: .get,
                    headers: [.authorization: "Bearer "+token, .init("X-Request-ID")!: "untrusted"]) { response in
                    let data = Data(response.body.readableBytesView)
                    let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: data)
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    XCTAssertEqual(Set(object.keys), ["schemaVersion", "code", "message", "requestId"])
                    XCTAssertEqual(envelope.schemaVersion, "1")
                    XCTAssertEqual(response.headers[.init("X-Request-ID")!], envelope.requestId.uuidString)
                    XCTAssertFalse(String(buffer: response.body).contains("secret"))
                    XCTAssertTrue(ids.insert(envelope.requestId).inserted)
                }
            }
        }
    }

    func testOnlyExactGetProbesArePublic() async throws {
        try await Self.app(token: Self.credential(), actor: UUID()).test(.router) { client in
            for path in ["/health/live", "/health/ready", "/health", "/ready"] {
                try await client.execute(uri: path, method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                    XCTAssertEqual(String(buffer: response.body), "{\"status\":\"alive\"}")
                    XCTAssertNotNil(response.headers[.init("X-Request-ID")!])
                }
                try await client.execute(uri: path, method: .post) { response in XCTAssertEqual(response.status, .unauthorized) }
            }
            try await client.execute(uri: "/health/live/data", method: .get) { response in XCTAssertEqual(response.status, .unauthorized) }
        }
    }

    func testOriginPolicyAndPreflight() async throws {
        let token = Self.credential()
        try await Self.app(token: token, actor: UUID()).test(.router) { client in
            for origin in ["null", "http://localhost:3000.evil", "https://evil.example"] {
                try await client.execute(uri: "/api/v1/identity", method: .get,
                    headers: [.authorization: "Bearer "+token, .origin: origin]) { response in
                    XCTAssertEqual(response.status, .forbidden)
                    XCTAssertNil(response.headers[.accessControlAllowOrigin])
                }
            }
            try await client.execute(uri: "/api/v1/identity", method: .options,
                headers: [.origin: "http://localhost:3000", .accessControlRequestMethod: "GET", .accessControlRequestHeaders: "Authorization, X-Actor-ID"]) { response in
                XCTAssertEqual(response.status, .noContent)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "http://localhost:3000")
            }
            try await client.execute(uri: "/api/v1/identity", method: .get,
                headers: [.authorization: "Bearer "+token, .origin: "http://localhost:3000"]) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.vary], "Origin")
            }
            try await client.execute(uri: "/api/v1/identity", method: .options,
                headers: [.origin: "http://localhost:3000", .accessControlRequestMethod: "TRACE"]) { response in
                XCTAssertEqual(response.status, .forbidden)
            }
        }
    }

    func testDuplicateSecurityHeadersAndUnapprovedPreflightAreRejected() async throws {
        let token = Self.credential()
        try await Self.app(token: token, actor: UUID()).test(.router) { client in
            var duplicateAuth: HTTPFields = [.authorization: "Bearer "+token]
            duplicateAuth.append(.init(name: .authorization, value: "Bearer "+token))
            try await client.execute(uri: "/api/v1/identity", method: .get, headers: duplicateAuth) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            var duplicateOrigin: HTTPFields = [.authorization: "Bearer "+token, .origin: "http://localhost:3000"]
            duplicateOrigin.append(.init(name: .origin, value: "https://evil.example"))
            try await client.execute(uri: "/api/v1/identity", method: .get, headers: duplicateOrigin) { response in
                XCTAssertEqual(response.status, .forbidden)
            }
            try await client.execute(uri: "/api/v1/identity", method: .options,
                headers: [.origin: "http://localhost:3000", .accessControlRequestMethod: "GET", .accessControlRequestHeaders: "X-Unapproved"]) { response in
                XCTAssertEqual(response.status, .forbidden)
            }
        }
    }

    func testDeadlineCancelsCooperativeRoute() async throws {
        let token = Self.credential()
        try await Self.app(token: token, actor: UUID(), timeout: .milliseconds(20)).test(.router) { client in
            try await client.execute(uri: "/api/v1/slow", method: .get, headers: [.authorization: "Bearer "+token]) { response in
                XCTAssertEqual(response.status, .gatewayTimeout)
                let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(response.body.readableBytesView))
                XCTAssertEqual(envelope.code, "TIMED_OUT")
            }
        }
    }

    func testSafeConfigurationAndDiagnosticRedaction() throws {
        let token = Self.credential(), actor = UUID()
        for origin in ["*", "null", "https://*.example", "http://remote.example", "https://user:password@example.com", "https://example.com/path", "https://example.com?token=secret"] {
            XCTAssertThrowsError(try BoundaryConfiguration(credential: token, actorID: actor, approvedOrigin: origin))
        }
        XCTAssertThrowsError(try BoundaryConfiguration(credential: "", actorID: actor, approvedOrigin: "http://localhost:3000"))
        XCTAssertThrowsError(try BoundaryConfiguration(credential: token, actorID: actor, approvedOrigin: "http://localhost:3000", requestTimeout: .zero))
        let config = try BoundaryConfiguration(credential: token, actorID: actor, approvedOrigin: "http://localhost:3000")
        XCTAssertEqual(config.listenHost, "127.0.0.1")
        XCTAssertFalse(String(describing: config).contains(token))
        XCTAssertFalse(String(reflecting: config).contains(token))
        XCTAssertFalse(config.authenticates("Bearer "+token+"x"))
    }

    func testPaginationDefaultsBoundariesAndInvalidCursors() throws {
        XCTAssertEqual(try PageRequest().limit, 50)
        XCTAssertNil(try PageRequest().after)
        XCTAssertEqual(try PageRequest(limit: "100", after: "9223372036854775807").after, Int64.max)
        for limit in ["0", "101", "-1", "1.0", "01", "999999999999999999999"] { XCTAssertThrowsError(try PageRequest(limit: limit)) }
        for cursor in ["0", "-1", "01", "opaque", "9223372036854775808"] { XCTAssertThrowsError(try PageRequest(after: cursor)) }
    }
}
