import Foundation
import SquidraCognition

/// Read-only archive of a host-grounded answer, not a new GroundedAnswer proof
/// or an execution grant. Publication recovery must verify runtime completion.
public struct StoredReadRunCompletion: Sendable {
    public let actorID: UUID, runID: UUID, requestID: UUID
    public let respondingVersion: Int64
    public let answerJSON: Data
    public init(actorID: UUID,runID: UUID,requestID: UUID,respondingVersion: Int64,answerJSON: Data) {
        self.actorID = actorID;self.runID = runID;self.requestID = requestID
        self.respondingVersion = respondingVersion;self.answerJSON = answerJSON
    }
}
public protocol ReadRunCompletionStore: Sendable {
    func save(snapshot: RunSnapshot, answer: GroundedAnswer, deadline: ContinuousClock.Instant) async throws
    func load(runID: UUID, deadline: ContinuousClock.Instant) async throws -> StoredReadRunCompletion?
}
