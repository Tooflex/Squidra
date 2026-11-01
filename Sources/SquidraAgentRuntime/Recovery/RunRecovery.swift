import Foundation
import SquidraDomain
import SquidraTools

/// Host adapter must verify the actual provider/target outcome. Nil means the
/// effect cannot be established, never permission to repeat it.
public protocol RunEffectVerifier: Sendable {
    func confirmedOutcome(for action: ActionRecord, deadline: ContinuousClock.Instant) async throws -> ActionResult?
}
public enum RunRecoveryResult: Sendable {
    case ready(RunController), waitingApproval(RunSnapshot), terminal(RunSnapshot)
}
/// Explicit host recovery after the previous worker/process has stopped. It is
/// not a live-worker takeover API. The host supplies the checkpoint version it
/// inspected; CAS rejects concurrent progress. No tool execution occurs here.
public struct RunRecovery: Sendable {
    private let runs: any RunStore, actions: any ActionLedgerStore
    private let verifier: any RunEffectVerifier
    private let clock: any SquidraDomain.Clock
    public init(runs: any RunStore, actions: any ActionLedgerStore, verifier: any RunEffectVerifier, clock: any SquidraDomain.Clock) {
        self.runs = runs;self.actions = actions;self.verifier = verifier;self.clock = clock
    }
    public func recover(actorID: UUID, runID: UUID, expectedVersion: Int64, actionID: UUID? = nil) async throws -> RunRecoveryResult {
        try Task.checkCancellation()
        var snapshot = try await runs.load(actorID:actorID,runID:runID,deadline:.now.advanced(by:.seconds(4)))
        try snapshot.validate()
        guard snapshot.actorID == actorID,snapshot.id == runID else { throw RunStoreError.corruptCheckpoint }
        guard snapshot.version == expectedVersion else { throw RunStoreError.conflict }
        if snapshot.state.isTerminal { return .terminal(snapshot) }
        // ApprovalWait owns revalidation of the exact approval binding and TTL.
        if snapshot.state == .waitingApproval { return .waitingApproval(snapshot) }
        guard let wallEnd = snapshot.deadlineSecondsSince1970 else { throw RunError.invalidCheckpoint }
        let tick = clock.monotonicElapsed()
        guard tick >= .zero else { throw RunError.clockRegression }
        let remaining = (wallEnd - (try clock.now()).secondsSince1970) * 1000
        guard remaining.isFinite else { throw RunError.invalidCheckpoint }
        let originalRemaining = snapshot.budget.activeMilliseconds - snapshot.activeMilliseconds
        guard remaining <= Double(originalRemaining) + 0.001 else { throw RunError.clockRegression }
        snapshot.activeMilliseconds = snapshot.budget.activeMilliseconds - Int64(max(0,remaining.rounded(.down)))
        if snapshot.activeMilliseconds >= snapshot.budget.activeMilliseconds {
            terminalize(&snapshot,code:.timedOut)
            return .terminal(try await save(snapshot))
        }
        // Fence stale controllers before consulting effect evidence. A failed or
        // ambiguous save returns no controller and grants no dispatch permit.
        snapshot = try await save(snapshot)
        if var invocation = snapshot.invocation,invocation.attempts > 0 {
            guard let actionID else {
                terminalize(&snapshot,code:.recoveryRequired)
                return .terminal(try await save(snapshot))
            }
            var action = try await actions.load(actorID:actorID,id:actionID,deadline:.now.advanced(by:.seconds(4)))
            guard action.command.actorID == actorID,action.command.runID == runID,
                  action.command.idempotencyKey == invocation.key,
                  action.command.fingerprintHex == snapshot.iteration?.semanticDigest else { throw RunError.invalidCheckpoint }
            if action.status == .pending || action.status == .unknown {
                let evidence = action
                let outcome = try await withThrowingTaskGroup(of:ActionResult?.self) { group in
                    let deadline = ContinuousClock.now.advanced(by:.seconds(4))
                    group.addTask {
                        do { return try await verifier.confirmedOutcome(for:evidence,deadline:deadline) }
                        catch is CancellationError { throw CancellationError() }
                        catch { return nil }
                    }
                    group.addTask { try await ContinuousClock().sleep(until:deadline);return nil }
                    defer { group.cancelAll() }
                    let completed: ActionResult?? = try await group.next()
                    return completed.flatMap { $0 }
                }
                guard let outcome else {
                    invocation.inFlight = false;invocation.outcome = .unknown;snapshot.invocation = invocation
                    terminalize(&snapshot,code:.recoveryRequired)
                    return .terminal(try await save(snapshot))
                }
                action = try await ActionLedger(store:actions).reconcile(action,confirmed:outcome,deadline:.now.advanced(by:.seconds(4)))
            }
            invocation.inFlight = false
            switch action.status {
            case .succeeded: invocation.outcome = .confirmed
            case .failed: invocation.outcome = .failed
            case .reserved:
                // No dispatch permit was issued from this reservation. Retry
                // uses the same key and consumes the original bounded budget.
                invocation.outcome = .retryableFailure
                invocation.retryAtActiveMilliseconds = snapshot.activeMilliseconds + 500
            default: throw RunError.reconciliationRequired
            }
            snapshot.invocation = invocation
            snapshot = try await save(snapshot)
        }
        // Charge recovery I/O before returning control; it is active work too.
        let controller = RunController(record:snapshot,store:runs,clock:clock,tick:tick)
        return .ready(controller)
    }
    private func save(_ value: RunSnapshot) async throws -> RunSnapshot {
        var next = value
        guard next.version < Int64.max else { throw RunError.invalidCheckpoint }
        next.version += 1
        try next.validate()
        try await runs.compareAndSet(next,expectedVersion:value.version,deadline:.now.advanced(by:.seconds(4)))
        return next
    }
    private func terminalize(_ snapshot: inout RunSnapshot, code: RunTerminalCode) {
        snapshot.state = code.state;snapshot.terminalCode = code;snapshot.substate = nil
        snapshot.deadlineSecondsSince1970 = nil;snapshot.invocation?.inFlight = false
    }
}
