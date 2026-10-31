import Logging
import PostgresNIO

internal enum PostgresTransportError: Error { case closed }

/// For small, explicitly bounded queries only. Serialize the liveness check and
/// query enqueue on the NIO event loop so cancellation cannot close the channel
/// between a Swift-task check and an unchecked write to a closed channel.
internal enum BoundedPostgresQuery {
    private static let logger = Logger(label: "squidra.postgres", factory: { _ in SwiftLogNoOpLogHandler() })
    static func rows(_ connection: PostgresConnection, _ query: PostgresQuery) async throws -> [PostgresRow] {
        try Task.checkCancellation()
        let result: PostgresQueryResult = try await connection.eventLoop.flatSubmit {
            guard !connection.isClosed else { return connection.eventLoop.makeFailedFuture(PostgresTransportError.closed) }
            return connection.query(query, logger: logger)
        }.get()
        return result.rows
    }
}
