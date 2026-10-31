import Foundation
import SquidraDomain
import SquidraSecurity

public enum ApprovalWaitResult: Sendable {
    case waiting(RunSnapshot), ready(RunController), refused(RunSnapshot)
}
/// Durable continuation, never a suspended human-waiting task or execution grant.
public struct ApprovalWait: Sendable {
    private let approvals: ApprovalCoordinator
    private let runs: any RunStore
    private let clock: any SquidraDomain.Clock
    public init(approvals: ApprovalCoordinator, runs: any RunStore, clock: any SquidraDomain.Clock) {
        self.approvals = approvals; self.runs = runs; self.clock = clock
    }
    public func suspend(_ controller: RunController, for approval: ApprovalRecord) async throws -> RunSnapshot {
        let snapshot = try await controller.snapshot()
        try match(snapshot,approval:approval)
        guard approval.decision == .pending else { throw ApprovalError.conflict }
        let stored = try await approvals.load(actorID:snapshot.actorID,id:approval.id,deadline:.now.advanced(by:.seconds(2)))
        guard stored == approval else { throw ApprovalError.conflict }
        guard try clock.now().secondsSince1970*1_000 < Double(approval.expiresAtMilliseconds) else { throw ApprovalError.expired }
        return try await controller.transition(to:.waitingApproval,substate:.waitingApproval)
    }
    public func resume(actorID: UUID, approvalID: UUID, deadline: ContinuousClock.Instant) async throws -> ApprovalWaitResult {
        let approval = try await approvals.load(actorID:actorID,id:approvalID,deadline:deadline)
        let controller = try await RunController.restoreWaiting(actorID:actorID,id:approval.binding.runID,store:runs,clock:clock)
        let snapshot = try await controller.snapshot()
        try match(snapshot,approval:approval)
        let expired = try clock.now().secondsSince1970*1_000 >= Double(approval.expiresAtMilliseconds)
        if approval.decision == .pending && !expired { return .waiting(snapshot) }
        if approval.decision == .approved && !expired {
            do {
                _ = try await approvals.verify(actorID:actorID,id:approvalID,binding:approval.binding,deadline:deadline)
                _ = try await controller.transition(to:.validating,substate:.policyCheck)
                return .ready(controller)
            } catch ApprovalError.expired {} catch ApprovalError.denied {} catch ApprovalError.notApproved {}
        }
        return .refused(try await controller.transition(to:.failed,terminalCode:.policyDenied))
    }
    private func match(_ snapshot: RunSnapshot, approval: ApprovalRecord) throws {
        let hash = approval.binding.commandHash.map { String(format:"%02x",$0) }.joined()
        guard snapshot.id == approval.binding.runID,snapshot.actorID == approval.binding.actorID,
              snapshot.iteration?.semanticDigest == hash,snapshot.invocation != nil else { throw ApprovalError.conflict }
    }
}
