import Foundation
import PostgresNIO
import Logging

public enum DatabaseReadiness: Equatable, Sendable {
    case ready
    case notReady(Failure)
    public enum Failure: String, Sendable { case database, migrations }
}

public struct SchemaMigration: Hashable, Sendable {
    public let namespace: String
    public let version: String
    public let checksum: String
    public init(namespace: String, version: String, checksum: String) {
        self.namespace = namespace; self.version = version; self.checksum = checksum
    }
}

/// Own the client's run task through ServiceLifecycle (or a structured task group).
/// A cancelled run closes the pool. No raw database errors escape this adapter.
public struct PostgresSchemaReadiness: Sendable {
    public enum Invalid: Error { case timeout }
    private let client: PostgresClient
    private let expected: Set<SchemaMigration>
    public init(client: PostgresClient, expected: Set<SchemaMigration> = ExpectedDatabaseSchema.migrations) {
        self.client = client; self.expected = expected
    }

    public func check(timeout: Duration = .seconds(2)) async throws -> DatabaseReadiness {
        guard timeout > .zero, timeout <= .seconds(5) else { throw Invalid.timeout }
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: DatabaseReadiness.self) { group in
            group.addTask { try await inspect() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .notReady(.database)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func inspect() async throws -> DatabaseReadiness {
        do {
            return try await client.withConnection(isolation: nil) { connection in
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await inspect(connection)
                } onCancel: {
                    // A future awaiting the initial SQL response is not itself
                    // cancellation-aware. Closing only this lease releases it.
                    connection.close().whenFailure { _ in }
                }
            }
        } catch {
            try Task.checkCancellation()
            return .notReady(.database)
        }
    }

    private func inspect(_ connection: PostgresConnection) async throws -> DatabaseReadiness {
        let logger = Logger(label: "squidra.readiness", factory: { _ in SwiftLogNoOpLogHandler() })
        do {
            let rows = try await connection.query("SELECT current_setting('server_version_num')::int", logger: logger)
            var versions: [Int] = []
            for try await value in rows.decode(Int.self) { versions.append(value) }
            guard versions.count == 1, (170000..<180000).contains(versions[0]) else { return .notReady(.database) }
        } catch {
            try Task.checkCancellation()
            return .notReady(.database)
        }
        do {
            let rows = try await connection.query("SELECT namespace, version, checksum FROM public.squidra_schema_migrations LIMIT \(expected.count + 1)", logger: logger)
            var actual = Set<SchemaMigration>()
            for try await (namespace, version, checksum) in rows.decode((String, String, String).self) {
                actual.insert(.init(namespace: namespace, version: version, checksum: checksum))
            }
            return actual == expected ? .ready : .notReady(.migrations)
        } catch {
            try Task.checkCancellation()
            return .notReady(.migrations)
        }
    }
}

/// This first profile only connects over loopback. TLS is disabled solely for
/// that trusted local transport; remote database deployment is separate work.
public struct LocalDatabaseConfiguration: Sendable, CustomStringConvertible, CustomReflectable {
    public enum Invalid: Error { case values }
    private let port: Int
    private let username: String
    private let password: String
    private let database: String
    public init(port: Int, username: String, password: String, database: String) throws {
        func identifier(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 63 && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
            }
        }
        guard (1...65535).contains(port), identifier(username), identifier(database),
              (32...256).contains(password.utf8.count),
              !password.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Invalid.values }
        self.port = port; self.username = username; self.password = password; self.database = database
    }
    public func makeClient() -> PostgresClient {
        var configuration = PostgresClient.Configuration(host: "127.0.0.1", port: port,
            username: username, password: password, database: database, tls: .disable)
        configuration.options.connectTimeout = .seconds(1)
        configuration.options.maximumConnections = 4
        configuration.options.additionalStartupParameters = [("options", "-c statement_timeout=4000 -c lock_timeout=3000")]
        // The driver's default background/query logger is disabled, including errors.
        return PostgresClient(configuration: configuration)
    }
    public var description: String { "LocalDatabaseConfiguration(credentials: [REDACTED])" }
    public var customMirror: Mirror { Mirror(self, children: ["credentials": "[REDACTED]"]) }
}
