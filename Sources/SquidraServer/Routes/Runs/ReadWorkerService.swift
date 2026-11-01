import ServiceLifecycle
import SquidraAgentRuntime

/// Joins recovery and execution before releasing ownership or stopping the DB.
struct ReadWorkerService: Service {
    let coordinator: PublishedReadRunCoordinator?
    let ownership: LocalRunOwnership?
    var recovery: (@Sendable () async throws -> Bool)? = nil
    func run() async throws {
        defer { ownership?.releaseAfterJoiningWorkers() }
        let signal = AsyncStream<Void>.makeStream()
        do {
            try await withTaskCancellationHandler {
                try await withGracefulShutdownHandler {
                    try await withThrowingTaskGroup(of:Void.self) { group in
                        group.addTask { for await _ in signal.stream {} }
                        if let recovery {
                            group.addTask {
                                do {
                                    while !Task.isCancelled {
                                        if try await recovery() { await Task.yield() }
                                        else { try await Task.sleep(for:.milliseconds(250)) }
                                    }
                                } catch is CancellationError { return }
                            }
                        }
                        defer { group.cancelAll() }
                        try await group.next()
                    }
                } onGracefulShutdown: { signal.continuation.finish() }
            } onCancel: { signal.continuation.finish() }
        } catch {
            await coordinator?.shutdown()
            throw error
        }
        await coordinator?.shutdown()
    }
}
