import ServiceLifecycle

/// Publishes completed archives; never dispatches models or tools.
struct PublicationRecoveryService: Service {
    let processNext: @Sendable () async throws -> Bool
    func run() async throws {
        let stop = AsyncStream<Void>.makeStream()
        try await withTaskCancellationHandler {
            try await withGracefulShutdownHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            while !Task.isCancelled {
                                if try await processNext() { await Task.yield() }
                                else { try await Task.sleep(for: .milliseconds(250)) }
                            }
                        } catch is CancellationError { return }
                    }
                    group.addTask { for await _ in stop.stream {} }
                    defer { group.cancelAll() }
                    try await group.next()
                }
            } onGracefulShutdown: { stop.continuation.finish() }
        } onCancel: { stop.continuation.finish() }
    }
}
