import Foundation
import SquidraDomain

/// Host-owned authorization context. Tool output/model text never supplies rules.
public struct ActionPolicyContext: Sendable {
    public let actorID: UUID, runID: UUID
    public let definition: ToolDefinition
    public let target: String
    public let arguments: Data
    public let scope: Set<String>
    public let idempotencyKey: String
    public let deadline: ContinuousClock.Instant
    public init(actorID: UUID, runID: UUID, definition: ToolDefinition, target: String, arguments: Data,
                scope: Set<String>, idempotencyKey: String, deadline: ContinuousClock.Instant) {
        self.actorID = actorID; self.runID = runID; self.definition = definition; self.target = target
        self.arguments = arguments; self.scope = scope; self.idempotencyKey = idempotencyKey; self.deadline = deadline
    }
}
public enum ActionPolicyDecision: Sendable { case allow, deny, requiresApproval }
public protocol PolicyEngine: Sendable {
    /// Implementations must cooperate with cancellation and must not execute effects.
    func evaluate(_ context: ActionPolicyContext) async throws -> ActionPolicyDecision
}
public struct DenyAllActionPolicy: PolicyEngine {
    public init() {}
    public func evaluate(_ context: ActionPolicyContext) -> ActionPolicyDecision { .deny }
}

/// Exact, atomic host grants: no wildcard actors, tools, capabilities or targets.
/// Delegation may supply a subset of this scope, never increase it.
public struct HostActionPermission: Sendable {
    public let actorID: UUID
    public let tool: ToolID
    public let capability: String
    public let targets: Set<String>, scope: Set<String>
    public let expiresAt: ContinuousClock.Instant
    public init(actorID: UUID, tool: ToolID, capability: String, targets: Set<String>, scope: Set<String>,
                expiresAt: ContinuousClock.Instant) {
        self.actorID = actorID; self.tool = tool; self.capability = capability
        self.targets = targets; self.scope = scope; self.expiresAt = expiresAt
    }
}
public struct HostActionPolicy: PolicyEngine {
    private let permissions: [HostActionPermission]
    public init(permissions: [HostActionPermission]) { self.permissions = permissions }
    public func evaluate(_ context: ActionPolicyContext) throws -> ActionPolicyDecision {
        try Task.checkCancellation()
        let now = ContinuousClock.now
        guard context.deadline > now, permissions.count <= 1_024,
              !context.scope.isEmpty, context.scope.count <= 256,
              permissions.contains(where: {
                  $0.actorID == context.actorID && $0.tool == context.definition.id
                  && $0.capability == context.definition.capability && $0.expiresAt > now
                  && $0.targets.contains(context.target) && context.scope.isSubset(of: $0.scope)
              }) else { return .deny }
        return context.definition.risk.rawValue >= ToolRisk.r2.rawValue ? .requiresApproval : .allow
    }
}
