import SquidraCognition

/// Narrow host-worker port. Implementations must cooperate with cancellation
/// and the request deadline. No effectful tool or crash-resume API is exposed.
public protocol ReadRunAnswerExecuting: Sendable {
    func executeAnswer(_ request: ReadRunRequest) async throws -> GroundedAnswer
}
extension ReadRunEngine: ReadRunAnswerExecuting {
    public func executeAnswer(_ request: ReadRunRequest) async throws -> GroundedAnswer {
        try await execute(request).answer
    }
}
