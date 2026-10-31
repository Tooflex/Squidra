import Foundation
import SquidraCognition
import SquidraDomain

public enum RunPublicationPhase: String, Equatable, Sendable {
    case unmanaged, running, succeeded, failed, cancelled, recoveryRequired = "recovery_required"
}
/// Opaque backend ownership, not a runtime/action permit. Never serialize it to
/// a client or retry execution after an ambiguous claim result.
public protocol RunPublicationClaim: Sendable {
    var binding: AGUIRunBinding { get }
    var executionExpiresAt: UTCInstant { get }
}
public enum RunPublicationOutcome: Sendable {
    case answer(GroundedAnswer, messageID: UUID)
    case failed(AGUIPublicFailure)
    case cancelled
}
public struct RunPublicationStatus: Sendable {
    public let phase: RunPublicationPhase, stream: AGUIRunStreamInfo, leaseExpired: Bool
    public init(phase: RunPublicationPhase, stream: AGUIRunStreamInfo, leaseExpired: Bool) {
        self.phase = phase;self.stream = stream;self.leaseExpired = leaseExpired
    }
}
/// Publication only: no model, runtime or tool dispatch/retry port exists here.
/// The host must create the stream first, dispatch only after a fresh successful
/// claim, and bound its worker by the returned execution deadline.
public protocol RunPublicationStore: Sendable {
    func claim(_ binding: AGUIRunBinding, maximumExecutionSeconds: Int, at: UTCInstant, deadline: ContinuousClock.Instant) async throws -> any RunPublicationClaim
    func finish(_ claim: any RunPublicationClaim, outcome: RunPublicationOutcome, at: UTCInstant, deadline: ContinuousClock.Instant) async throws -> RunPublicationStatus
    func status(actorID: UUID, runID: UUID, deadline: ContinuousClock.Instant) async throws -> RunPublicationStatus
    func recoverExpired(actorID: UUID, runID: UUID, at: UTCInstant, deadline: ContinuousClock.Instant) async throws -> RunPublicationStatus
}
