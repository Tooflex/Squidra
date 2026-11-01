import Foundation
import Hummingbird
import HummingbirdTesting
import SquidraSecurity
import SquidraObservability
import XCTest
@testable import SquidraServer

final class CredentialHTTPTests: XCTestCase, @unchecked Sendable {
    func testHostInjectionDoesNotRequireAuthSecretInPublicSettings() async throws {
        let token = String(repeating: "a3", count: 32), reference = CredentialReference()
        let provider = RotatingCredentialProvider(reference: reference, value: try BearerCredential(token))
        let settings = ["SQUIDRA_ACTOR_ID": UUID().uuidString, "SQUIDRA_UI_ORIGIN": "http://localhost:3000",
                        "SQUIDRA_DB_PORT": "5432", "SQUIDRA_DB_USER": "squidra", "SQUIDRA_DB_NAME": "squidra",
                        "SQUIDRA_DB_PASSWORD": String(repeating: "test-db-only-", count: 3)]
        let config = try ServerConfiguration(environment: settings, credentialProvider: provider, credentialReference: reference)
        let accepted = try await config.boundary.authenticates("Bearer " + token)
        XCTAssertTrue(accepted)
        XCTAssertFalse(String(reflecting: config).contains(token))
        XCTAssertThrowsError(try ServerConfiguration(environment: settings, credentialProvider: provider))
        XCTAssertThrowsError(try ServerConfiguration(environment: settings, credentialReference: reference))
    }

    private static func app(provider: any CredentialProvider, reference: CredentialReference,
                            timeout: Duration = .seconds(2)) throws -> some ApplicationProtocol {
        let router = Router(context: BoundaryContext.self)
        router.get("/api/v1/identity") { _, context in context.actorID!.uuidString }
        let config = try BoundaryConfiguration(credentialProvider: provider, credentialReference: reference,
            actorID: UUID(), approvedOrigin: "http://localhost:3000", requestTimeout: timeout)
        return Application(responder: HTTPBoundary(inner: router.buildResponder(), configuration: config))
    }

    func testRotationIsEffectiveOnNextRequestAndSecretsStayOutOfResponsesAndSpans() async throws {
        let old = String(repeating: "a1", count: 32), new = String(repeating: "b2", count: 32)
        let reference = CredentialReference()
        let provider = RotatingCredentialProvider(reference: reference, value: try BearerCredential(old))
        let recorder = PrivateTraceRecorder(limits: try TraceLimits())
        try await recorder.withTrace(try TraceCorrelation(runID: UUID())) { _ in
            try await Self.app(provider: provider, reference: reference).test(.router) { client in
                try await client.execute(uri: "/api/v1/identity", method: .get, headers: [.authorization: "Bearer " + old]) { response in
                    XCTAssertEqual(response.status, .ok)
                    XCTAssertFalse(String(buffer: response.body).contains(old))
                }
                _ = try await provider.rotate(try BearerCredential(new), reference: reference, expectedVersion: 0)
                for (token, status) in [(old, HTTPResponse.Status.unauthorized), (new, .ok)] {
                    try await client.execute(uri: "/api/v1/identity", method: .get, headers: [.authorization: "Bearer " + token]) { response in
                        XCTAssertEqual(response.status, status)
                        XCTAssertFalse(String(buffer: response.body).contains(old))
                        XCTAssertFalse(String(buffer: response.body).contains(new))
                    }
                }
                _ = try await provider.rotate(nil, reference: reference, expectedVersion: 1)
                try await client.execute(uri: "/api/v1/identity", method: .get, headers: [.authorization: "Bearer " + new]) { response in
                    XCTAssertNotEqual(response.status, .ok)
                    XCTAssertFalse(String(buffer: response.body).contains(new))
                }
            }
        }
        let snapshot = await recorder.snapshot()
        XCTAssertFalse(snapshot.spans.isEmpty)
        let serialized = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(serialized.contains(old)); XCTAssertFalse(serialized.contains(new))
    }

    func testSlowAndThrowingProvidersDoNotAuthenticateOrExposeErrors() async throws {
        let token = String(repeating: "d", count: 64)
        for provider: any CredentialProvider in [FailingProvider(), SlowProvider()] {
            try await Self.app(provider: provider, reference: CredentialReference(), timeout: .milliseconds(20)).test(.router) { client in
                let start = ContinuousClock.now
                try await client.execute(uri: "/api/v1/identity", method: .get, headers: [.authorization: "Bearer " + token]) { response in
                    XCTAssertNotEqual(response.status, .ok)
                    XCTAssertFalse(String(buffer: response.body).contains("SECRET_PROVIDER_CANARY"))
                    XCTAssertFalse(String(buffer: response.body).contains(token))
                }
                XCTAssertLessThan(start.duration(to: .now), .seconds(2))
            }
        }
    }
}

private struct FailingProvider: CredentialProvider {
    struct Failure: Error { let value = "SECRET_PROVIDER_CANARY" }
    func credential(for reference: CredentialReference, deadline: ContinuousClock.Instant) async throws -> BearerCredential { throw Failure() }
}
private struct SlowProvider: CredentialProvider {
    func credential(for reference: CredentialReference, deadline: ContinuousClock.Instant) async throws -> BearerCredential {
        try await Task.sleep(for: .seconds(60))
        throw CredentialError.unavailable
    }
}
