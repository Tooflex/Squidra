import Foundation
import Hummingbird
import HummingbirdTesting
import SquidraPostgres
import XCTest
@testable import SquidraServer

// SAFETY: no mutable instance state. Remove when the runner supports Swift Testing.
final class LifecycleTests: XCTestCase, @unchecked Sendable {
    private static func configuration() throws -> ServerConfiguration {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["SQUIDRA_TEST_DB_PORT"], let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            throw ServerConfiguration.Invalid.requiredValues
        }
        let credential = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        return try ServerConfiguration(environment: ["SQUIDRA_PORT":"0", "SQUIDRA_AUTH_TOKEN":credential,
            "SQUIDRA_ACTOR_ID":UUID().uuidString, "SQUIDRA_UI_ORIGIN":"http://localhost:3000",
            "SQUIDRA_DB_PORT":port, "SQUIDRA_DB_USER":"squidra", "SQUIDRA_DB_PASSWORD":password, "SQUIDRA_DB_NAME":"squidra"])
    }

    func testRealDatabaseProbesAndAliasesOverLiveHTTP() async throws {
        let app = ServerComposition.live(configuration: try Self.configuration())
        try await app.test(.live) { client in
            for path in ["/health/live", "/health"] {
                try await client.execute(uri: path, method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                    XCTAssertEqual(String(buffer: response.body), "{\"status\":\"alive\"}")
                    XCTAssertNotNil(response.headers[.init("X-Request-ID")!])
                }
            }
            // Offline composition has no model service; its absence cannot gate readiness.
            for path in ["/health/ready", "/ready"] {
                try await client.execute(uri: path, method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                    XCTAssertEqual(String(buffer: response.body), "{\"status\":\"ready\"}")
                }
            }
            try await client.execute(uri: "/api/v1/unknown", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
        // The live framework gracefully stopped the application, including its client service.
    }

    func testUnavailableDependenciesKeepLivenessAndMinimalReadiness() async throws {
        let configuration = try Self.configuration()
        for failure in [DatabaseReadiness.Failure.database, .migrations] {
            let app = ServerComposition.application(configuration: configuration, readiness: { .notReady(failure) })
            try await app.test(.live) { client in
                try await client.execute(uri: "/health", method: .get) { response in XCTAssertEqual(response.status, .ok) }
                for path in ["/health/ready", "/ready"] {
                    try await client.execute(uri: path, method: .get) { response in
                        XCTAssertEqual(response.status, .serviceUnavailable)
                        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String:String])
                        XCTAssertEqual(object, ["status":"not_ready", "dependency":failure.rawValue])
                    }
                }
            }
        }
    }

    func testConfigurationRejectsMissingValuesAndUnavailableProfiles() {
        XCTAssertThrowsError(try ServerConfiguration(environment: [:]))
        XCTAssertThrowsError(try ServerConfiguration(environment: ["SQUIDRA_PROFILE":"cloud"]))
        XCTAssertThrowsError(try ServerConfiguration(environment: ["SQUIDRA_PORT":"-1"]))
    }
}
