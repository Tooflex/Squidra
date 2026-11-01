import ServiceLifecycle
import SquidraAgentRuntime

/// Add after the database client. ServiceGroup gracefully stops services in
/// reverse order, so joined worker publication completes before client shutdown.
struct ReadWorkerService: Service {
    let coordinator: PublishedReadRunCoordinator
    let ownership: LocalRunOwnership?
    func run() async throws {
        let signal = AsyncStream<Void>.makeStream()
        await withTaskCancellationHandler {
            await withGracefulShutdownHandler {
                for await _ in signal.stream {}
            } onGracefulShutdown: { signal.continuation.finish() }
        } onCancel: { signal.continuation.finish() }
        await coordinator.shutdown()
        ownership?.releaseAfterJoiningWorkers()
    }
}
