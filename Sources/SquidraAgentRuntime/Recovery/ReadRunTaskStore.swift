import Foundation

public enum ReadRunTaskError: Error, Equatable, Sendable {
    case invalidState, conflict, unavailable, timeout, cancelled
}
/// Immutable original task, not execution authority. Recovery must revalidate
/// current host permissions and preserve runtime budget/checkpoint state.
public struct StoredReadRunTask: Sendable {
    public let request: ReadRunRequest
    public let threadID: UUID
    public init(request: ReadRunRequest, threadID: UUID) {
        self.request = request; self.threadID = threadID
    }
}
public protocol ReadRunTaskStore: Sendable {
    func save(_ task: StoredReadRunTask, deadline: ContinuousClock.Instant) async throws
    func load(runID: UUID, deadline: ContinuousClock.Instant) async throws -> StoredReadRunTask?
}
