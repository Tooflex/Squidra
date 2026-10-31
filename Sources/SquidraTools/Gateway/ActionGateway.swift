import Foundation
import SquidraSecurity

public enum ActionGatewayError: Error, Equatable, Sendable {
    case denied, policyUnavailable, approvalRequired, timedOut, outcomeUnconfirmed
}
public enum ToolSurface: Sendable { case bounded, unrestrictedShell, unrestrictedSQL, unrestrictedHTTP }
public struct GatewayToolRegistration: Sendable {
    public let definition: ToolDefinition
    public let surface: ToolSurface
    public let executor: any ToolExecutor
    let resolveTarget: @Sendable (Data) throws -> String
    public init(definition: ToolDefinition, surface: ToolSurface, executor: any ToolExecutor,
                resolveTarget: @escaping @Sendable (Data) throws -> String) {
        self.definition = definition; self.surface = surface; self.executor = executor; self.resolveTarget = resolveTarget
    }
}
public struct GatewayAction: Sendable {
    public let actorID: UUID, runID: UUID
    public let tool: ToolID
    public let target: String
    public let arguments: Data
    public let scope: Set<String>
    public let idempotencyKey: String
    public let deadline: ContinuousClock.Instant
    public init(actorID: UUID, runID: UUID, tool: ToolID, target: String, arguments: Data,
                scope: Set<String>, idempotencyKey: String, deadline: ContinuousClock.Instant) {
        self.actorID = actorID; self.runID = runID; self.tool = tool; self.target = target
        self.arguments = arguments; self.scope = scope; self.idempotencyKey = idempotencyKey; self.deadline = deadline
    }
}
public enum GatewayActionResult: Sendable {
    case completed(UntrustedToolResult)
    case replay(ActionRecord)
    case inProgress(ActionRecord)
    case reconciliationRequired(ActionRecord)
}

/// Sole production dispatcher. The composition root supplies host policy and
/// bounded adapters; HTTP/model/tool data cannot mint execution grants.
public struct ActionGateway: Sendable {
    private let catalog: ToolCatalog
    private let registrations: [ToolID:GatewayToolRegistration]
    private let policy: any PolicyEngine
    private let ledger: ActionLedger?
    public init(tools: [GatewayToolRegistration], policy: any PolicyEngine = DenyAllActionPolicy(), ledger: ActionLedger? = nil) throws {
        guard tools.count <= 256, tools.allSatisfy({ $0.surface == .bounded }) else { throw ActionGatewayError.denied }
        catalog = try ToolCatalog(definitions: tools.map(\.definition))
        registrations = Dictionary(uniqueKeysWithValues: tools.map { ($0.definition.id,$0) })
        self.policy = policy; self.ledger = ledger
    }
    public func invoke(_ action: GatewayAction) async throws -> GatewayActionResult {
        try Task.checkCancellation()
        guard let registration = registrations[action.tool] else { throw ToolError.unknownTool }
        let definition = registration.definition
        let now = ContinuousClock.now
        guard action.deadline > now else { throw ActionGatewayError.timedOut }
        let deadline = min(action.deadline, now.advanced(by: .milliseconds(definition.timeoutMilliseconds)))
        let input = try catalog.validateInput(action.arguments, for: action.tool)
        do {
            guard try registration.resolveTarget(input) == action.target else { throw ActionGatewayError.denied }
        } catch { throw ActionGatewayError.denied }
        let command = try ActionCommand(actorID: action.actorID, runID: action.runID, tool: action.tool,
            idempotencyKey: action.idempotencyKey, target: action.target, arguments: input, scope: Array(action.scope))
        guard !action.scope.isEmpty else { throw ActionGatewayError.denied }
        let context = ActionPolicyContext(actorID: action.actorID, runID: action.runID, definition: definition,
            target: action.target, arguments: input, scope: action.scope, idempotencyKey: action.idempotencyKey, deadline: deadline)
        try await authorize(context)
        // Mandatory approval cannot be waived by a permissive/custom policy.
        // SQD-009 supplies verified approvals; R4 also needs extra tool controls.
        guard definition.risk.rawValue < ToolRisk.r2.rawValue else { throw ActionGatewayError.approvalRequired }
        let needsLedger = definition.risk != .r0 || definition.idempotency != .readOnly
        var permit: ActionDispatchPermit?
        if needsLedger {
            guard let ledger else { throw ActionGatewayError.denied }
            switch try await ledger.prepare(command, deadline: databaseDeadline(deadline)) {
            case .dispatch(let claimed): permit = claimed
            case .replay(let record):
                if let result = record.result, result.status == .succeeded {
                    guard let payload = result.payload else { throw ActionLedgerError.corruptRecord }
                    _ = try catalog.validateOutput(payload, for: action.tool)
                }
                return .replay(record)
            case .inProgress(let record): return .inProgress(record)
            case .reconciliationRequired(let record): return .reconciliationRequired(record)
            }
        }
        do { try await authorize(context) }
        catch {
            // No executor has run: a durable not-applied result is justified.
            // If cancellation/storage prevents this write, pending remains safe.
            if let permit, let ledger {
                _ = try? await ledger.complete(permit, result: .failed(.notApplied), deadline: databaseDeadline(deadline))
            }
            throw error
        }
        let grant = ToolExecutionGrant(actorID: action.actorID, runID: action.runID, definition: definition, target: action.target,
            input: input, scope: action.scope, idempotencyKey: action.idempotencyKey, deadline: deadline)
        let result: UntrustedToolResult
        do { result = try await catalog.invoke(action.tool, input: input, grant: grant, executor: registration.executor) }
        catch {
            if let permit, let ledger {
                _ = try? await ledger.markUnknown(permit, deadline: databaseDeadline(deadline))
            }
            throw error
        }
        if let permit, let ledger {
            do {
                _ = try await ledger.complete(permit, result: .succeeded(result, for: action.tool), deadline: databaseDeadline(deadline))
            } catch is CancellationError { throw CancellationError() }
            catch { throw ActionGatewayError.outcomeUnconfirmed }
        }
        return .completed(result)
    }
    private func databaseDeadline(_ deadline: ContinuousClock.Instant) -> ContinuousClock.Instant {
        min(deadline, .now.advanced(by: .seconds(4)))
    }
    private func authorize(_ context: ActionPolicyContext) async throws {
        do {
            let decision = try await withThrowingTaskGroup(of: ActionPolicyDecision.self) { group in
                group.addTask { try await policy.evaluate(context) }
                group.addTask { try await Task.sleep(until: context.deadline); throw ActionGatewayError.timedOut }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < context.deadline else { throw ActionGatewayError.timedOut }
            switch decision {
            case .allow: return
            case .deny: throw ActionGatewayError.denied
            case .requiresApproval: throw ActionGatewayError.approvalRequired
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ActionGatewayError { throw error }
        catch { throw ActionGatewayError.policyUnavailable }
    }
}
