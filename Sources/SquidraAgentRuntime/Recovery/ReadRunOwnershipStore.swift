import Foundation

public struct StoredReadRunOwner: Sendable {
    public let actorID: UUID,runID: UUID,ownerID: UUID
    public init(actorID: UUID,runID: UUID,ownerID: UUID) { self.actorID = actorID;self.runID = runID;self.ownerID = ownerID }
}
/// Register before publication claim/worker dispatch. Implementations must reject
/// a released local ownership handle and a different actor-domain/file binding.
public protocol ReadRunOwnershipStore: Sendable {
    func register(runID: UUID,deadline: ContinuousClock.Instant) async throws
}
