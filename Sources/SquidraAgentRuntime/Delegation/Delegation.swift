import Foundation

public enum DelegationError: Error, Equatable, Sendable {
    case invalidContract, denied, budgetExceeded, depthExceeded, closed, timedOut
}

/// Explicit host allocation, never inferred from the task text. Reservations
/// count worst-case usage, including failed/unknown attempts; there are no refunds.
public struct DelegationBudget: Sendable, Equatable {
    public let steps: Int, calls: Int, tokens: Int, costMicroUSD: Int64
    public let milliseconds: Int64
    public init(steps: Int, calls: Int, tokens: Int, costMicroUSD: Int64, milliseconds: Int64) throws {
        guard (1...20).contains(steps), (0...15).contains(calls), (0...1_000_000).contains(tokens),
              (0...1_000_000_000).contains(costMicroUSD), (1...180_000).contains(milliseconds) else {
            throw DelegationError.invalidContract
        }
        self.steps = steps; self.calls = calls; self.tokens = tokens
        self.costMicroUSD = costMicroUSD; self.milliseconds = milliseconds
    }
}

/// Exact capability/resource pairs avoid a Cartesian-product scope escalation.
/// These are host grants, not approval records or authorization to bypass a gateway.
public struct DelegationGrant: Hashable, Sendable {
    public let capability: String, resourceID: UUID
    public init(capability: String, resourceID: UUID) throws {
        guard !capability.isEmpty, capability.utf8.count <= 128,
              capability.utf8.allSatisfy({ (33...126).contains($0) }) else { throw DelegationError.invalidContract }
        self.capability = capability; self.resourceID = resourceID
    }
}

public struct DelegationTask: Sendable {
    public let instruction: String
    public let grants: Set<DelegationGrant>
    public let budget: DelegationBudget
    public init(instruction: String, grants: Set<DelegationGrant>, budget: DelegationBudget) throws {
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instruction.utf8.count <= 8192, !instruction.contains("\0"), grants.count <= 256 else {
            throw DelegationError.invalidContract
        }
        self.instruction = instruction; self.grants = grants; self.budget = budget
    }
}

/// No arbitrary error text, prompts or provider payloads in correlated traces.
public struct DelegationTrace: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let actorID: UUID, traceID: UUID, rootRunID: UUID, parentRunID: UUID, childRunID: UUID
    public let depth: Int
    public let outcome: DelegationOutcome
}
public enum DelegationOutcome: String, Codable, Sendable {
    case completed, failed, cancelled, timedOut, denied, budgetExceeded, depthExceeded
}
public struct DelegationResult: Sendable {
    public let trace: DelegationTrace
    /// Untrusted data. This string never grants authority or proves a tool effect.
    public let output: String?
}

/// Trusted host executor only. Provider text is never executable Swift. Adapters
/// must use context.perform before each model/tool attempt (including retries),
/// and the existing gateway for policy/approval/idempotency. No shell port exists.
public protocol DelegationExecuting: Sendable {
    func execute(_ task: DelegationTask, context: DelegationContext) async throws -> String
}

/// A process-scoped allocation tree. Create one root from the host's explicitly
/// reserved allowance; do not recreate it to replenish an ongoing run. No crash
/// resume or persistent-effect recovery is exposed by this API.
public struct DelegationContext: Sendable {
    private let tree: DelegationTree
    private let id: UUID
    public let actorID: UUID, traceID: UUID, rootRunID: UUID
    public let depth: Int
    public let deadline: ContinuousClock.Instant
    public var runID: UUID { id }

    public static func root(actorID: UUID, runID: UUID, traceID: UUID,
                            grants: Set<DelegationGrant>, budget: DelegationBudget) throws -> Self {
        guard grants.count <= 256 else { throw DelegationError.invalidContract }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(budget.milliseconds))
        let tree = DelegationTree(rootID: runID, grants: grants, budget: budget, deadline: deadline)
        return Self(tree: tree, id: runID, actorID: actorID, traceID: traceID,
                    rootRunID: runID, depth: 0, deadline: deadline)
    }

    /// Reserve one step and one attempt before invoking a trusted adapter. Token
    /// and cost arguments are upper bounds, not caller-reported usage after dispatch.
    /// The adapter must enforce these bounds at the provider/tool boundary.
    public func perform<T: Sendable>(grant: DelegationGrant, tokens: Int, costMicroUSD: Int64,
                                    operation: @Sendable @escaping (ContinuousClock.Instant) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try await tree.consume(id, grant: grant, tokens: tokens, cost: costMicroUSD)
        let value = try await bounded(deadline: deadline) {
            try Task.checkCancellation()
            try await tree.check(id)
            return try await operation(deadline)
        }
        try await tree.check(id)
        return value
    }

    /// A validated delegation costs one parent step plus the entire child
    /// allocation, atomically. Nested grants must be subsets of the immediate
    /// parent; empty means no capabilities, never "inherit".
    public func delegate(_ task: DelegationTask, to executor: any DelegationExecuting) async throws -> DelegationResult {
        try Task.checkCancellation()
        let childID = UUID(), childDepth = depth + 1
        let childDeadline = min(deadline, .now.advanced(by: .milliseconds(task.budget.milliseconds)))
        try await tree.reserve(parent: id, child: childID, task: task, depth: childDepth, deadline: childDeadline)
        let context = Self(tree: tree, id: childID, actorID: actorID, traceID: traceID,
                           rootRunID: rootRunID, depth: childDepth, deadline: childDeadline)
        let outcome: DelegationOutcome, output: String?
        do {
            let value = try await bounded(deadline: childDeadline) { try await executor.execute(task, context: context) }
            try await tree.check(childID)
            guard value.utf8.count <= 16_384, !value.contains("\0") else { throw DelegationError.invalidContract }
            outcome = .completed; output = value
        } catch is CancellationError { outcome = .cancelled; output = nil }
        catch let error as DelegationError {
            switch error {
            case .timedOut: outcome = .timedOut
            case .budgetExceeded: outcome = .budgetExceeded
            case .depthExceeded: outcome = .depthExceeded
            case .denied: outcome = .denied
            default: outcome = .failed
            }
            output = nil
        } catch { outcome = .failed; output = nil }
        await tree.close(childID)
        return DelegationResult(trace: DelegationTrace(schemaVersion: 1, actorID: actorID, traceID: traceID,
            rootRunID: rootRunID, parentRunID: id, childRunID: childID, depth: childDepth, outcome: outcome), output: output)
    }

    /// Host termination invalidates all descendants via their ancestor chain.
    public func close() async { await tree.close(id) }
}

private actor DelegationTree {
    struct Node {
        let parent: UUID?, grants: Set<DelegationGrant>, deadline: ContinuousClock.Instant
        var steps: Int, calls: Int, tokens: Int, cost: Int64, milliseconds: Int64
        var closed = false
        init(parent: UUID?, grants: Set<DelegationGrant>, budget: DelegationBudget, deadline: ContinuousClock.Instant) {
            self.parent = parent; self.grants = grants; self.deadline = deadline
            steps = budget.steps; calls = budget.calls; tokens = budget.tokens
            cost = budget.costMicroUSD; milliseconds = budget.milliseconds
        }
    }
    var nodes: [UUID: Node]
    init(rootID: UUID, grants: Set<DelegationGrant>, budget: DelegationBudget, deadline: ContinuousClock.Instant) {
        nodes = [rootID: Node(parent: nil, grants: grants, budget: budget, deadline: deadline)]
    }
    func check(_ id: UUID) throws {
        try Task.checkCancellation()
        var current: UUID? = id
        while let key = current {
            guard let node = nodes[key], !node.closed else { throw DelegationError.closed }
            guard ContinuousClock.now < node.deadline else { throw DelegationError.timedOut }
            current = node.parent
        }
    }
    func reserve(parent: UUID, child: UUID, task: DelegationTask, depth: Int, deadline: ContinuousClock.Instant) throws {
        try check(parent)
        guard depth <= 3 else { throw DelegationError.depthExceeded }
        guard var node = nodes[parent], task.grants.isSubset(of: node.grants) else { throw DelegationError.denied }
        let b = task.budget
        guard node.steps >= b.steps + 1, node.calls >= b.calls, node.tokens >= b.tokens,
              node.cost >= b.costMicroUSD, node.milliseconds >= b.milliseconds else { throw DelegationError.budgetExceeded }
        node.steps -= b.steps + 1; node.calls -= b.calls; node.tokens -= b.tokens
        node.cost -= b.costMicroUSD; node.milliseconds -= b.milliseconds
        nodes[parent] = node
        nodes[child] = Node(parent: parent, grants: task.grants, budget: b, deadline: deadline)
    }
    func consume(_ id: UUID, grant: DelegationGrant, tokens: Int, cost: Int64) throws {
        try check(id)
        guard tokens >= 0, cost >= 0 else { throw DelegationError.invalidContract }
        guard var node = nodes[id], node.grants.contains(grant) else { throw DelegationError.denied }
        guard node.steps > 0, node.calls > 0, node.tokens >= tokens, node.cost >= cost else { throw DelegationError.budgetExceeded }
        node.steps -= 1; node.calls -= 1; node.tokens -= tokens; node.cost -= cost
        nodes[id] = node
    }
    func close(_ id: UUID) { nodes[id]?.closed = true }
}

/// Structured concurrency joins a cancelled child before reporting completion.
/// A non-cooperative host adapter can delay return; it cannot be force-killed.
private func bounded<T: Sendable>(deadline: ContinuousClock.Instant,
    operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw DelegationError.timedOut }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await ContinuousClock().sleep(until: deadline)
            throw DelegationError.timedOut
        }
        defer { group.cancelAll() }
        let value = try await group.next()!
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw DelegationError.timedOut }
        return value
    }
}
