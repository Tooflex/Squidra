import Foundation
import SquidraDomain

/// Host-only state/budget coordinator. Tool effects and approval decisions are
/// separate ports; a transition never proves an effect or grants approval.
public actor RunController {
    private var record: RunSnapshot
    private let store: any RunStore
    private let clock: any SquidraDomain.Clock
    private var lastTick: Duration?
    private var detached = false

    init(record: RunSnapshot, store: any RunStore, clock: any SquidraDomain.Clock, tick: Duration?) {
        self.record = record; self.store = store; self.clock = clock; self.lastTick = tick
    }
    public static func create(actorID: UUID, id: UUID = UUID(), traceID: UUID = UUID(),
                              budget: RunBudget = try! RunBudget(), store: any RunStore,
                              clock: any SquidraDomain.Clock) async throws -> RunController {
        let tick = clock.monotonicElapsed()
        guard tick >= .zero else { throw RunError.clockRegression }
        var record = RunSnapshot(id: id, actorID: actorID, traceID: traceID, budget: budget)
        record.deadlineSecondsSince1970 = try deadline(record, clock: clock)
        try record.validate()
        try await store.create(record, deadline: .now.advanced(by: .seconds(2)))
        return RunController(record: record, store: store, clock: clock, tick: tick)
    }

    /// Host-only continuation after the old worker has stopped. These states
    /// precede tool reservation. PLANNING additionally requires a validated archive
    /// supplied by the engine; ordinary early continuation excludes that state.
    static func restoreBeforePlanning(actorID: UUID,id: UUID,traceID: UUID,expectedVersion: Int64,
        store: any RunStore,clock: any SquidraDomain.Clock,allowPlanning: Bool = false) async throws -> RunController {
        var record = try await store.load(actorID:actorID,runID:id,deadline:.now.advanced(by:.seconds(4)))
        try record.validate()
        guard record.actorID == actorID,record.id == id,record.traceID == traceID,record.version == expectedVersion,
              ([.created,.validating,.contextLoading].contains(record.state) || (allowPlanning && record.state == .planning)),record.steps == 0,record.calls == 0,
              record.iteration == nil,record.invocation == nil,let wallEnd = record.deadlineSecondsSince1970 else { throw RunError.recoveryRequired }
        let tick = clock.monotonicElapsed(),now = try clock.now().secondsSince1970
        let remaining = (wallEnd-now)*1000
        guard tick >= .zero,remaining.isFinite,remaining <= Double(record.budget.activeMilliseconds-record.activeMilliseconds)+0.001 else { throw RunError.clockRegression }
        record.activeMilliseconds = record.budget.activeMilliseconds-Int64(max(0,remaining.rounded(.down)))
        // Persist the same rounded deadline as the charged integer budget. Otherwise
        // a retry after a lost CAS acknowledgement looks like clock regression.
        record.deadlineSecondsSince1970 = min(wallEnd,now+Double(record.budget.activeMilliseconds-record.activeMilliseconds)/1000)
        if record.activeMilliseconds >= record.budget.activeMilliseconds {
            record.state = .timedOut;record.terminalCode = .timedOut;record.substate = nil;record.deadlineSecondsSince1970 = nil
        }
        guard record.version < Int64.max else { throw RunError.invalidCheckpoint }
        record.version += 1
        try record.validate()
        try await store.compareAndSet(record,expectedVersion:expectedVersion,deadline:.now.advanced(by:.seconds(4)))
        return RunController(record:record,store:store,clock:clock,tick:tick)
    }

    /// Explicitly reattach only a durable approval wait. Active crash recovery is
    /// deferred to SQD-028: losing a monotonic anchor must not replenish budgets.
    public static func restoreWaiting(actorID: UUID, id: UUID, store: any RunStore,
                                      clock: any SquidraDomain.Clock) async throws -> RunController {
        let record = try await store.load(actorID: actorID, runID: id, deadline: .now.advanced(by: .seconds(2)))
        try record.validate()
        guard record.actorID == actorID, record.id == id else { throw RunStoreError.corruptCheckpoint }
        guard !record.state.isTerminal else { throw RunError.terminal }
        guard record.state == .waitingApproval else { throw RunError.recoveryRequired }
        return RunController(record: record, store: store, clock: clock, tick: nil)
    }
    public func snapshot() throws -> RunSnapshot {
        guard !detached else { throw RunError.recoveryRequired }
        return record
    }

    public func transition(to next: RunState, substate: RunSubstate? = nil,
                           terminalCode: RunTerminalCode? = nil) async throws -> RunSnapshot {
        var (candidate, tick) = try charged()
        if expire(&candidate) { return try await persist(candidate, tick: tick) }
        guard next != .timedOut, next != .budgetExceeded else { throw RunError.invalidTransition }
        guard record.state.permits(next), substate.map({ $0.publicState == next }) ?? true else { throw RunError.invalidTransition }
        guard candidate.invocation?.inFlight != true || next.isTerminal else { throw RunError.attemptInFlight }
        if [.executingTool, .waitingApproval, .responding].contains(next) {
            guard candidate.iteration != nil else { throw RunError.invalidProposal }
        }
        if next == .executingTool && candidate.invocation == nil { throw RunError.invalidProposal }
        if next == .completed && candidate.iteration != nil { throw RunError.invalidProposal }
        if next.isTerminal {
            guard let terminalCode, terminalCode.state == next else { throw RunError.invalidTransition }
            candidate.terminalCode = terminalCode
            candidate.invocation?.inFlight = false
        } else if terminalCode != nil { throw RunError.invalidTransition }
        candidate.state = next; candidate.substate = substate
        return try await persist(candidate, tick: tick)
    }

    /// The digest must be computed by the host over semantic operation/version/
    /// target/arguments/effective scope, excluding IDs, timestamps and keys.
    public func validatedProposal(semanticDigest: String, invocationKey: String? = nil,
                                  delegationDepth: Int = 0) async throws -> RunSnapshot {
        var (candidate, tick) = try charged()
        if expire(&candidate) { return try await persist(candidate, tick: tick) }
        guard candidate.state == .planning, candidate.iteration == nil, RunSnapshot.validDigest(semanticDigest),
              delegationDepth >= 0, invocationKey.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else { throw RunError.invalidProposal }
        if candidate.steps >= candidate.budget.steps { terminate(&candidate, .stepLimit) }
        else if delegationDepth > candidate.budget.depth { terminate(&candidate, .depthLimit) }
        else {
            candidate.steps += 1
            candidate.maximumDelegationDepth = max(candidate.maximumDelegationDepth, delegationDepth)
            candidate.iteration = .init(startState: candidate.state, semanticDigest: semanticDigest)
            candidate.invocation = invocationKey.map { .init(key: $0) }
        }
        return try await persist(candidate, tick: tick)
    }

    public func rejectedProposal(semanticDigest: String) async throws -> RunSnapshot {
        var (candidate, tick) = try charged()
        if expire(&candidate) { return try await persist(candidate, tick: tick) }
        guard candidate.state == .planning, candidate.iteration == nil, RunSnapshot.validDigest(semanticDigest) else { throw RunError.invalidProposal }
        accountIteration(&candidate, iteration: .init(startState: .planning, semanticDigest: semanticDigest), progress: .none)
        return try await persist(candidate, tick: tick)
    }

    public func finishIteration(progress: HostVerifiedProgress) async throws -> RunSnapshot {
        var (candidate, tick) = try charged()
        if expire(&candidate) { return try await persist(candidate, tick: tick) }
        guard candidate.state != .waitingApproval, let iteration = candidate.iteration, candidate.invocation?.inFlight != true else { throw RunError.invalidProposal }
        accountIteration(&candidate, iteration: iteration, progress: progress)
        candidate.iteration = nil; candidate.invocation = nil
        return try await persist(candidate, tick: tick)
    }

    public func reserveToolAttempt(timeoutMilliseconds: Int64) async throws -> ToolAttemptPermit? {
        var (candidate, tick) = try charged()
        if expire(&candidate) { _ = try await persist(candidate, tick: tick); return nil }
        guard candidate.state == .executingTool, candidate.iteration != nil,
              var invocation = candidate.invocation, (1...180_000).contains(timeoutMilliseconds) else { throw RunError.invalidProposal }
        guard !invocation.inFlight else { throw RunError.attemptInFlight }
        if invocation.attempts > 0 {
            guard invocation.outcome != .unknown else { throw RunError.reconciliationRequired }
            guard invocation.outcome == .retryableFailure else { throw RunError.notRetryable }
        }
        if candidate.calls >= candidate.budget.calls { terminate(&candidate, .callLimit) }
        else if invocation.attempts > candidate.budget.retries { terminate(&candidate, .retryLimit) }
        else {
            if invocation.attempts > 0 {
                guard candidate.activeMilliseconds >= (invocation.retryAtActiveMilliseconds ?? Int64.max) else { throw RunError.retryBackoff }
            }
            invocation.attempts += 1; invocation.inFlight = true; invocation.outcome = nil
            invocation.retryAtActiveMilliseconds = nil
            candidate.invocation = invocation; candidate.calls += 1
        }
        let saved = try await persist(candidate, tick: tick)
        guard !saved.state.isTerminal else { return nil }
        // Persisting the reservation is active I/O too. Recheck before granting
        // dispatch, and give the gateway an absolute monotonic deadline.
        var (afterCommit, afterTick) = try charged()
        if expire(&afterCommit) { _ = try await persist(afterCommit, tick: afterTick); return nil }
        let remaining = min(timeoutMilliseconds, saved.budget.activeMilliseconds - afterCommit.activeMilliseconds)
        return ToolAttemptPermit(runID: saved.id, actorID: saved.actorID, idempotencyKey: invocation.key,
            retryOrdinal: invocation.attempts - 1,
            timeoutMilliseconds: remaining, deadline: .now.advanced(by: .milliseconds(remaining)))
    }

    /// Caller must persist an authoritative tool outcome in the ledger first.
    public func finishToolAttempt(_ outcome: AttemptOutcome) async throws -> RunSnapshot {
        var (candidate, tick) = try charged()
        if expire(&candidate) { return try await persist(candidate, tick: tick) }
        guard candidate.state == .executingTool, var invocation = candidate.invocation, invocation.inFlight else { throw RunError.invalidProposal }
        invocation.inFlight = false; invocation.outcome = outcome
        if outcome == .retryableFailure {
            invocation.retryAtActiveMilliseconds = candidate.activeMilliseconds + (invocation.attempts == 1 ? 500 : 1_000)
        }
        candidate.invocation = invocation
        return try await persist(candidate, tick: tick)
    }

    private func charged() throws -> (RunSnapshot, Duration) {
        try Task.checkCancellation()
        guard !detached else { throw RunError.recoveryRequired }
        guard !record.state.isTerminal else { throw RunError.terminal }
        let tick = clock.monotonicElapsed()
        guard tick >= .zero else { throw RunError.clockRegression }
        var candidate = record
        if let lastTick {
            guard tick >= lastTick else { throw RunError.clockRegression }
            let delta = tick - lastTick
            let parts = delta.components
            let product = parts.seconds.multipliedReportingOverflow(by: 1_000)
            let fraction = (parts.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
            let sum = product.partialValue.addingReportingOverflow(fraction)
            let elapsed = candidate.activeMilliseconds.addingReportingOverflow(sum.partialValue)
            candidate.activeMilliseconds = product.overflow || sum.overflow || elapsed.overflow ? Int64.max : elapsed.partialValue
        }
        return (candidate, tick)
    }
    private func expire(_ candidate: inout RunSnapshot) -> Bool {
        if candidate.activeMilliseconds >= candidate.budget.activeMilliseconds { terminate(&candidate, .timedOut); return true }
        return false
    }
    private func terminate(_ candidate: inout RunSnapshot, _ code: RunTerminalCode) {
        candidate.state = code.state; candidate.terminalCode = code; candidate.substate = nil
        candidate.invocation?.inFlight = false
    }
    private func accountIteration(_ candidate: inout RunSnapshot, iteration: IterationCheckpoint, progress: HostVerifiedProgress) {
        switch progress {
        case .newEvidence, .confirmedEffect, .validatedResponse:
            candidate.noProgressRepetitions = 0; candidate.lastNoProgressIteration = nil
        case .none:
            candidate.noProgressRepetitions = candidate.lastNoProgressIteration == iteration ? candidate.noProgressRepetitions + 1 : 1
            candidate.lastNoProgressIteration = iteration
            if candidate.noProgressRepetitions >= candidate.budget.repetitions { terminate(&candidate, .loopDetected) }
        }
    }
    private static func deadline(_ candidate: RunSnapshot, clock: any SquidraDomain.Clock) throws -> Double? {
        if candidate.state.isTerminal || candidate.state == .waitingApproval { return nil }
        let seconds = try clock.now().secondsSince1970 + Double(candidate.budget.activeMilliseconds - candidate.activeMilliseconds) / 1_000
        return try UTCInstant(secondsSince1970: seconds).secondsSince1970
    }
    private func persist(_ value: RunSnapshot, tick: Duration) async throws -> RunSnapshot {
        var candidate = value
        guard candidate.version < Int64.max else { throw RunError.invalidCheckpoint }
        candidate.version += 1
        candidate.deadlineSecondsSince1970 = try Self.deadline(candidate, clock: clock)
        try candidate.validate()
        do {
            try await store.compareAndSet(candidate, expectedVersion: record.version, deadline: .now.advanced(by: .seconds(2)))
        } catch {
            // A lost acknowledgement may follow a committed write. Never issue
            // another permit from an unconfirmed in-memory checkpoint.
            detached = true
            throw error
        }
        record = candidate
        lastTick = candidate.state == .waitingApproval || candidate.state.isTerminal ? nil : tick
        return candidate
    }
}
