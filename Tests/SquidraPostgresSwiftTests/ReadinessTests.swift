import Foundation
import Logging
import PostgresNIO
import SquidraPostgres
import XCTest

// SAFETY: no mutable test-instance state; each integration owns its container.
// Remove when the issue runner supports Swift Testing.
final class ReadinessTests: XCTestCase, @unchecked Sendable {
    private static let logger = Logger(label: "squidra.test", factory: { _ in SwiftLogNoOpLogHandler() })

    private static func assertStatus(_ actual: DatabaseReadiness, _ expected: DatabaseReadiness,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func testRealSchemaReadinessTimeoutCancellationAndPoolLifecycle() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let portText = env["SQUIDRA_TEST_DB_PORT"], let port = Int(portText),
              let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            XCTFail("Run through Scripts/test-issue.sh DB-CLIENT; a real isolated database is required")
            return
        }
        let config = try LocalDatabaseConfiguration(port: port, username: "squidra", password: password, database: "squidra")
        XCTAssertFalse(String(reflecting: config).contains(password))
        let client = config.makeClient()
        let probe = PostgresSchemaReadiness(client: client)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            defer { group.cancelAll() }
            Self.assertStatus(try await probe.check(), .ready)
            // Real lock: the probe must close its own blocked connection on timeout.
            try await client.withConnection(isolation: nil) { blocker in
                _ = try await blocker.query("BEGIN", logger: Self.logger).collect()
                _ = try await blocker.query("LOCK TABLE public.squidra_schema_migrations IN ACCESS EXCLUSIVE MODE", logger: Self.logger).collect()
                let start = ContinuousClock.now
                let result = try await probe.check(timeout: .milliseconds(100))
                // Wider than scheduling jitter, shorter than the 3-second server lock timeout.
                XCTAssertLessThan(start.duration(to: .now), .seconds(2))
                XCTAssertEqual(result, .notReady(.database))
                _ = try await blocker.query("ROLLBACK", logger: Self.logger).collect()
            }
            Self.assertStatus(try await probe.check(), .ready)
            // Explicit cancellation must propagate instead of becoming a health result.
            let cancelled = Task { try await probe.check() }
            cancelled.cancel()
            do { _ = try await cancelled.value; XCTFail("Cancelled check succeeded") }
            catch is CancellationError {} // expected
            // Use bound parameters for metadata values, even in test-only SQL.
            let migration = try XCTUnwrap(ExpectedDatabaseSchema.migrations.first)
            _ = try await client.query("UPDATE public.squidra_schema_migrations SET checksum=repeat('0',64) WHERE namespace=\(migration.namespace) AND version=\(migration.version)").collect()
            Self.assertStatus(try await probe.check(), .notReady(.migrations))
            _ = try await client.query("UPDATE public.squidra_schema_migrations SET checksum=\(migration.checksum) WHERE namespace=\(migration.namespace) AND version=\(migration.version)").collect()
            Self.assertStatus(try await probe.check(), .ready)
            _ = try await client.query("INSERT INTO public.squidra_schema_migrations(namespace,version,checksum) VALUES('future','999_future.sql',repeat('f',64))").collect()
            Self.assertStatus(try await probe.check(), .notReady(.migrations))
            _ = try await client.query("DELETE FROM public.squidra_schema_migrations WHERE namespace='future'").collect()
            _ = try await client.query("DELETE FROM public.squidra_schema_migrations WHERE namespace=\(migration.namespace) AND version=\(migration.version)").collect()
            Self.assertStatus(try await probe.check(), .notReady(.migrations))
            _ = try await client.query("DROP TABLE public.squidra_schema_migrations").collect()
            Self.assertStatus(try await probe.check(), .notReady(.migrations))
        }
        // run() returned, so the pool is closed; it cannot continue serving queries.
        do { _ = try await client.query("SELECT 1").collect(); XCTFail("Closed pool accepted a query") }
        catch {} // the raw error remains inside the test and is not printed
    }

    func testUnavailableDatabaseIsBoundedWithoutRawErrors() async throws {
        let client = PostgresClient(configuration: .init(unixSocketPath: "/tmp/squidra-missing-\(UUID().uuidString).sock", username: "squidra", password: nil, database: "squidra"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            defer { group.cancelAll() }
            Self.assertStatus(try await PostgresSchemaReadiness(client: client).check(timeout: .milliseconds(100)), .notReady(.database))
        }
    }

    func testInvalidConfigurationDoesNotExposeValues() throws {
        for port in [0, 65536] {
            XCTAssertThrowsError(try LocalDatabaseConfiguration(port: port, username: "squidra", password: String(repeating: "a", count: 32), database: "squidra"))
        }
        XCTAssertThrowsError(try LocalDatabaseConfiguration(port: 5432, username: "bad user", password: "short", database: "squidra"))
    }
}
