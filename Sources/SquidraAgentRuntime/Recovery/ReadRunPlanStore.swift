import Foundation
import SquidraCognition

public struct StoredReadRunPlan: Sendable {
    public let actorID: UUID,runID: UUID,requestID: UUID,planningVersion: Int64,archive: Data
    public init(actorID: UUID,runID: UUID,requestID: UUID,planningVersion: Int64,archive: Data) {
        self.actorID = actorID;self.runID = runID;self.requestID = requestID;self.planningVersion = planningVersion;self.archive = archive
    }
}
public protocol ReadRunPlanStore: Sendable {
    func save(snapshot: RunSnapshot,requestID: UUID,plan: PlannedRead,deadline: ContinuousClock.Instant) async throws
    func load(runID: UUID,deadline: ContinuousClock.Instant) async throws -> StoredReadRunPlan?
}
