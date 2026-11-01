import Foundation
import SquidraCognition

/// Raw model response and reservation, not a grounded answer or a dispatch grant.
public struct StoredReadRunAnswer: Sendable {
    public let actorID: UUID,runID: UUID,requestID: UUID,respondingVersion: Int64,archive: Data
    public init(actorID: UUID,runID: UUID,requestID: UUID,respondingVersion: Int64,archive: Data) {
        self.actorID = actorID;self.runID = runID;self.requestID = requestID;self.respondingVersion = respondingVersion;self.archive = archive
    }
}
public protocol ReadRunAnswerStore: Sendable {
    func save(snapshot: RunSnapshot,response: RoutedModelResponse,deadline: ContinuousClock.Instant) async throws
    func load(runID: UUID,deadline: ContinuousClock.Instant) async throws -> StoredReadRunAnswer?
}
