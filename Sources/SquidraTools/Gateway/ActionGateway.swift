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
    public let approvalID: UUID?
    public init(actorID: UUID, runID: UUID, tool: ToolID, target: String, arguments: Data,
                scope: Set<String>, idempotencyKey: String, deadline: ContinuousClock.Instant, approvalID: UUID? = nil) {
        self.approvalID = approvalID
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
    private let approvals: ApprovalCoordinator?
    public init(tools: [GatewayToolRegistration], policy: any PolicyEngine = DenyAllActionPolicy(),
                ledger: ActionLedger? = nil, approvals: ApprovalCoordinator? = nil) throws {
        guard tools.count <= 256, tools.allSatisfy({ $0.surface == .bounded }) else { throw ActionGatewayError.denied }
        catalog = try ToolCatalog(definitions: tools.map(\.definition))
        registrations = Dictionary(uniqueKeysWithValues: tools.map { ($0.definition.id,$0) })
        self.policy = policy; self.ledger = ledger; self.approvals = approvals
    }
    private struct Prepared: Sendable {
        let registration: GatewayToolRegistration
        let context: ActionPolicyContext
        let command: ActionCommand
    }
    private struct ApprovalReference: Sendable { let id: UUID; let binding: ApprovalBinding }

    /// Persists a request and returns immediately. No worker waits for a decision.
    public func requestApproval(_ action: GatewayAction) async throws -> ApprovalRecord {
        let prepared = try prepare(action),context = prepared.context
        let decision = try await evaluate(context)
        guard context.definition.risk != .r4 else { throw ActionGatewayError.denied }
        guard requiresApproval(context,decision:decision), let approvals, let ledger else { throw ActionGatewayError.denied }
        let reserved = try await ledger.reserveForApproval(prepared.command,deadline:databaseDeadline(context.deadline))
        guard reserved.status == .reserved else { throw ActionGatewayError.outcomeUnconfirmed }
        let binding = try approvalBinding(reserved,action:action)
        return try await approvals.request(binding,deadline:databaseDeadline(context.deadline))
    }
    public func invoke(_ action: GatewayAction) async throws -> GatewayActionResult {
        let prepared = try prepare(action),context = prepared.context
        let decision = try await evaluate(context)
        // Approval cannot waive missing R4 tool-specific extra controls.
        guard context.definition.risk != .r4 else { throw ActionGatewayError.approvalRequired }
        let needsApproval = requiresApproval(context,decision:decision)
        let needsLedger = needsApproval || context.definition.risk != .r0 || context.definition.idempotency != .readOnly
        var permit: ActionDispatchPermit?,reference: ApprovalReference?
        if needsLedger {
            guard let ledger else { throw needsApproval ? ActionGatewayError.approvalRequired : .denied }
            let preparation: ActionPreparation
            if needsApproval {
                guard let approvals, let id = action.approvalID else { throw ActionGatewayError.approvalRequired }
                let record = try await ledger.reserveForApproval(prepared.command,deadline:databaseDeadline(context.deadline))
                let binding = try approvalBinding(record,action:action)
                _ = try await approvals.verify(actorID:action.actorID,id:id,binding:binding,deadline:databaseDeadline(context.deadline))
                reference = ApprovalReference(id:id,binding:binding)
                preparation = try await ledger.claimApproved(record,deadline:databaseDeadline(context.deadline))
            } else { preparation = try await ledger.prepare(prepared.command,deadline:databaseDeadline(context.deadline)) }
            switch preparation {
            case .dispatch(let claimed): permit = claimed
            case .replay(let record):
                if let result = record.result, result.status == .succeeded {
                    guard let payload = result.payload else { throw ActionLedgerError.corruptRecord }
                    _ = try catalog.validateOutput(payload,for:action.tool)
                }
                return .replay(record)
            case .inProgress(let record): return .inProgress(record)
            case .reconciliationRequired(let record): return .reconciliationRequired(record)
            }
        }
        let grant = ToolExecutionGrant(actorID:action.actorID,runID:action.runID,definition:context.definition,
            target:action.target,input:context.arguments,scope:action.scope,idempotencyKey:action.idempotencyKey,deadline:context.deadline)
        let state = DispatchState(),approvedReference = reference
        let executor = GuardedExecutor(base:prepared.registration.executor,state:state,before:{
            let current = try await evaluate(context)
            if requiresApproval(context,decision:current) {
                guard let approvals,let approvedReference else { throw ActionGatewayError.approvalRequired }
                _ = try await approvals.verify(actorID:action.actorID,id:approvedReference.id,binding:approvedReference.binding,
                    deadline:databaseDeadline(context.deadline))
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < context.deadline else { throw ActionGatewayError.timedOut }
        })
        let result: UntrustedToolResult
        do { result = try await catalog.invoke(action.tool,input:context.arguments,grant:grant,executor:executor) }
        catch {
            let (began,rejection) = await state.snapshot()
            if let permit,let ledger {
                // Owned cleanup survives caller cancellation and an exhausted
                // attempt deadline. Await it before reporting the interrupted call.
                let cleanup = Task {
                    let deadline = ContinuousClock.now.advanced(by:.seconds(4))
                    if began { _ = try await ledger.markUnknown(permit,deadline:deadline) }
                    else { _ = try await ledger.complete(permit,result:.failed(.notApplied),deadline:deadline) }
                }
                do { try await cleanup.value }
                catch { throw ActionGatewayError.outcomeUnconfirmed }
            }
            throw rejection ?? error
        }
        if let permit,let ledger {
            do { _ = try await ledger.complete(permit,result:.succeeded(result,for:action.tool),deadline:databaseDeadline(context.deadline)) }
            catch is CancellationError { throw CancellationError() }
            catch { throw ActionGatewayError.outcomeUnconfirmed }
        }
        return .completed(result)
    }
    private func prepare(_ action: GatewayAction) throws -> Prepared {
        try Task.checkCancellation()
        guard let registration = registrations[action.tool] else { throw ToolError.unknownTool }
        let now = ContinuousClock.now
        guard action.deadline > now else { throw ActionGatewayError.timedOut }
        let deadline = min(action.deadline,now.advanced(by:.milliseconds(registration.definition.timeoutMilliseconds)))
        let input = try catalog.validateInput(action.arguments,for:action.tool)
        do { guard try registration.resolveTarget(input) == action.target else { throw ActionGatewayError.denied } }
        catch { throw ActionGatewayError.denied }
        let command = try ActionCommand(actorID:action.actorID,runID:action.runID,tool:action.tool,idempotencyKey:action.idempotencyKey,
            target:action.target,arguments:input,scope:Array(action.scope))
        guard !action.scope.isEmpty else { throw ActionGatewayError.denied }
        let context = ActionPolicyContext(actorID:action.actorID,runID:action.runID,definition:registration.definition,
            target:action.target,arguments:input,scope:action.scope,idempotencyKey:action.idempotencyKey,deadline:deadline)
        return Prepared(registration:registration,context:context,command:command)
    }
    private func approvalBinding(_ record: ActionRecord, action: GatewayAction) throws -> ApprovalBinding {
        guard record.command.actorID == action.actorID,record.command.runID == action.runID else { throw ApprovalError.conflict }
        return try ApprovalBinding(actorID:action.actorID,runID:action.runID,ledgerID:record.id,commandHash:record.command.fingerprint)
    }
    private func requiresApproval(_ context: ActionPolicyContext, decision: ActionPolicyDecision) -> Bool {
        context.definition.risk.rawValue >= ToolRisk.r2.rawValue || decision == .requiresApproval
    }
    private func databaseDeadline(_ deadline: ContinuousClock.Instant) -> ContinuousClock.Instant { min(deadline,.now.advanced(by:.seconds(4))) }
    private func evaluate(_ context: ActionPolicyContext) async throws -> ActionPolicyDecision {
        do {
            let decision = try await withThrowingTaskGroup(of:ActionPolicyDecision.self) { group in
                group.addTask { try await policy.evaluate(context) }
                group.addTask { try await Task.sleep(until:context.deadline);throw ActionGatewayError.timedOut }
                defer { group.cancelAll() };return try await group.next()!
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < context.deadline else { throw ActionGatewayError.timedOut }
            guard decision != .deny else { throw ActionGatewayError.denied }
            return decision
        } catch is CancellationError { throw CancellationError() }
        catch let error as ActionGatewayError { throw error }
        catch { throw ActionGatewayError.policyUnavailable }
    }
}

private actor DispatchState {
    private var began = false
    private var rejection: (any Error)?
    func begin() { began = true }
    func reject(_ error: any Error) { rejection = error }
    func snapshot() -> (Bool,(any Error)?) { (began,rejection) }
}
private struct GuardedExecutor: ToolExecutor {
    let base: any ToolExecutor
    let state: DispatchState
    let before: @Sendable () async throws -> Void
    func execute(_ call: ToolCall) async throws -> Data {
        do { try await before() }
        catch { await state.reject(error);throw error }
        await state.begin()
        try Task.checkCancellation()
        guard ContinuousClock.now < call.deadline else { throw ToolError.timedOut }
        return try await base.execute(call)
    }
}
