import Foundation
import SquidraDomain

public enum RunState: String, Codable, Sendable, CaseIterable {
    case created = "CREATED", validating = "VALIDATING", contextLoading = "CONTEXT_LOADING", planning = "PLANNING"
    case waitingApproval = "WAITING_APPROVAL", executingTool = "EXECUTING_TOOL", responding = "RESPONDING"
    case completed = "COMPLETED", failed = "FAILED", cancelled = "CANCELLED", timedOut = "TIMED_OUT", budgetExceeded = "BUDGET_EXCEEDED"
    public var isTerminal: Bool { [.completed, .failed, .cancelled, .timedOut, .budgetExceeded].contains(self) }
    public func permits(_ next: RunState) -> Bool {
        guard !isTerminal else { return false }
        if [.failed, .cancelled, .timedOut, .budgetExceeded].contains(next) { return true }
        switch self {
        case .created: return next == .validating
        case .validating: return [.contextLoading, .planning, .waitingApproval, .executingTool, .responding].contains(next)
        case .contextLoading: return next == .planning
        case .planning: return [.validating, .waitingApproval, .executingTool, .responding].contains(next)
        case .waitingApproval: return next == .validating // revalidate before effects
        case .executingTool: return [.planning, .responding].contains(next)
        case .responding: return [.planning, .completed].contains(next)
        default: return false
        }
    }
}

public enum RunSubstate: String, Codable, Sendable, CaseIterable {
    case reasoning = "REASONING", proposed = "PROPOSED", policyCheck = "POLICY_CHECK"
    case approvalRequired = "APPROVAL_REQUIRED", waitingApproval = "WAITING_APPROVAL"
    case executing = "EXECUTING", observingResult = "OBSERVING_RESULT", persisting = "PERSISTING", responding = "RESPONDING"
    public var publicState: RunState {
        switch self {
        case .reasoning, .proposed: .planning
        case .policyCheck: .validating
        case .approvalRequired, .waitingApproval: .waitingApproval
        case .executing, .observingResult, .persisting: .executingTool
        case .responding: .responding
        }
    }
}

public enum RunTerminalCode: String, Codable, Sendable {
    case completed = "COMPLETED", failed = "FAILED", cancelled = "CANCELLED", timedOut = "TIMED_OUT"
    case stepLimit = "STEP_LIMIT", callLimit = "CALL_LIMIT", depthLimit = "DEPTH_LIMIT", retryLimit = "RETRY_LIMIT"
    case loopDetected = "LOOP_DETECTED", policyDenied = "POLICY_DENIED", recoveryRequired = "RECOVERY_REQUIRED"
    public var state: RunState {
        switch self {
        case .completed: .completed
        case .failed, .policyDenied, .recoveryRequired: .failed
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        default: .budgetExceeded
        }
    }
}

/// Profiles may tighten the frozen ADR-001 ceilings, never raise them here.
public struct RunBudget: Codable, Equatable, Sendable {
    public let steps: Int, calls: Int, depth: Int, retries: Int, repetitions: Int
    public let activeMilliseconds: Int64
    public init(steps: Int = 20, calls: Int = 15, depth: Int = 3, retries: Int = 2,
                repetitions: Int = 3, activeMilliseconds: Int64 = 180_000) throws {
        self.steps = steps; self.calls = calls; self.depth = depth; self.retries = retries
        self.repetitions = repetitions; self.activeMilliseconds = activeMilliseconds
        try validate()
    }
    func validate() throws {
        guard (1...20).contains(steps), (1...15).contains(calls), (0...3).contains(depth),
              (0...2).contains(retries), (1...3).contains(repetitions), (1...180_000).contains(activeMilliseconds) else {
            throw RunError.invalidCheckpoint
        }
    }
}

public enum RunError: Error, Equatable, Sendable {
    case invalidCheckpoint, invalidTransition, invalidProposal, terminal, attemptInFlight
    case retryBackoff, notRetryable, reconciliationRequired, recoveryRequired, clockRegression
}

public enum AttemptOutcome: String, Codable, Sendable { case confirmed, retryableFailure, failed, unknown }

/// Only trusted host code supplies these after contract-specific verification.
/// Provider text, new IDs, transitions and ledger reservations are not progress.
/// validatedResponse requires a completed host grounding check, including a
/// legitimate unknown answer; it does not claim new evidence or an effect.
public enum HostVerifiedProgress: Sendable { case none, newEvidence, confirmedEffect, validatedResponse }

struct InvocationCheckpoint: Codable, Equatable, Sendable {
    var key: String
    var attempts = 0
    var inFlight = false
    var outcome: AttemptOutcome?
    var retryAtActiveMilliseconds: Int64?
}
struct IterationCheckpoint: Codable, Equatable, Sendable {
    let startState: RunState
    let semanticDigest: String
}

/// Versioned internal storage checkpoint, not the external RunState API DTO.
/// Numeric deadline is internal; public time DTOs still require RFC 3339.
public struct RunSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: UUID, actorID: UUID, traceID: UUID
    public let budget: RunBudget
    public internal(set) var version: Int64
    public internal(set) var state: RunState
    public internal(set) var substate: RunSubstate?
    public internal(set) var steps: Int, calls: Int, maximumDelegationDepth: Int
    public internal(set) var activeMilliseconds: Int64
    public internal(set) var deadlineSecondsSince1970: Double?
    public internal(set) var terminalCode: RunTerminalCode?
    public internal(set) var noProgressRepetitions: Int
    var lastNoProgressIteration: IterationCheckpoint?
    var iteration: IterationCheckpoint?
    var invocation: InvocationCheckpoint?

    init(id: UUID, actorID: UUID, traceID: UUID, budget: RunBudget) {
        self.schemaVersion = 1; self.id = id; self.actorID = actorID; self.traceID = traceID; self.budget = budget
        self.version = 1; self.state = .created; self.steps = 0; self.calls = 0; self.maximumDelegationDepth = 0
        self.activeMilliseconds = 0; self.noProgressRepetitions = 0
    }

    public func validate() throws {
        try budget.validate()
        guard schemaVersion == 1, version > 0, (0...budget.steps).contains(steps), (0...budget.calls).contains(calls),
              (0...budget.depth).contains(maximumDelegationDepth), activeMilliseconds >= 0,
              (0...budget.repetitions).contains(noProgressRepetitions),
              substate.map({ $0.publicState == state }) ?? true,
              state.isTerminal == (terminalCode != nil), terminalCode.map({ $0.state == state }) ?? true,
              state != .waitingApproval || deadlineSecondsSince1970 == nil,
              (noProgressRepetitions == 0 ? lastNoProgressIteration == nil : lastNoProgressIteration != nil),
              (noProgressRepetitions == budget.repetitions) == (terminalCode == .loopDetected),
              activeMilliseconds < budget.activeMilliseconds || state == .timedOut,
              state != .timedOut || activeMilliseconds >= budget.activeMilliseconds,
              iteration == nil || steps > 0,
              state != .waitingApproval || iteration != nil else {
            throw RunError.invalidCheckpoint
        }
        if let deadlineSecondsSince1970 { _ = try UTCInstant(secondsSince1970: deadlineSecondsSince1970) }
        for value in [iteration, lastNoProgressIteration].compactMap({ $0 }) {
            guard Self.validDigest(value.semanticDigest), value.startState == .planning else { throw RunError.invalidCheckpoint }
        }
        if let invocation {
            guard iteration != nil, !invocation.key.isEmpty, invocation.key.utf8.count <= 256,
                  (0...(budget.retries+1)).contains(invocation.attempts), invocation.attempts <= calls,
                  !invocation.inFlight || (state == .executingTool && invocation.attempts > 0),
                  invocation.retryAtActiveMilliseconds.map({ $0 >= 0 }) ?? true else { throw RunError.invalidCheckpoint }
        }
    }
    static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct ToolAttemptPermit: Equatable, Sendable {
    public let runID: UUID, actorID: UUID
    public let idempotencyKey: String
    public let retryOrdinal: Int
    public let timeoutMilliseconds: Int64
    public let deadline: ContinuousClock.Instant
}
