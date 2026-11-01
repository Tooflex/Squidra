import Foundation
import SquidraAgentRuntime
import SquidraCognition
import SquidraDomain
import SquidraProtocols

public enum ReadRunSubmissionError: Error, Equatable, Sendable {
    case invalidRequest, busy, conflict, closed, cancelled, recoveryRequired
}
/// Host-owned lifetime, separate from HTTP connections. No worker is restored
/// from status/replay, and no execution follows an ambiguous publication claim.
public actor PublishedReadRunCoordinator {
    private let actorID: UUID
    private let executor: any ReadRunAnswerExecuting
    private let events: any RunEventStore
    private let publication: any RunPublicationStore
    private let tasks: (any ReadRunTaskStore)?
    private let clock: any SquidraDomain.Clock
    private let maximumConcurrentRuns: Int, retentionSeconds: Int
    private var accepting = true
    private var reservations: Set<UUID> = []
    private var cancellationRequests: Set<UUID> = []
    private var workers: [UUID:Task<Void,Never>] = [:]
    private var shutdownWaiters: [CheckedContinuation<Void,Never>] = []
    public init(actorID: UUID, executor: any ReadRunAnswerExecuting, events: any RunEventStore, publication: any RunPublicationStore,
                clock: any SquidraDomain.Clock, tasks: (any ReadRunTaskStore)? = nil, maximumConcurrentRuns: Int = 4, retentionSeconds: Int = 3600) throws {
        guard (1...8).contains(maximumConcurrentRuns),(186...604_800).contains(retentionSeconds) else { throw ReadRunSubmissionError.invalidRequest }
        self.actorID = actorID;self.executor = executor;self.events = events;self.publication = publication;self.clock = clock;self.tasks = tasks
        self.maximumConcurrentRuns = maximumConcurrentRuns;self.retentionSeconds = retentionSeconds
    }
    public var activeCount: Int { reservations.count }
    public var isAccepting: Bool { accepting }
    public func submit(_ request: ReadRunRequest, threadID: UUID) async throws -> AGUIRunBinding {
        guard accepting else { throw ReadRunSubmissionError.closed }
        guard !Task.isCancelled else { throw ReadRunSubmissionError.cancelled }
        guard request.actorID == actorID,request.question.utf8.count <= 4096,
              !request.question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,request.effectiveToolScope == ["world:read"] else { throw ReadRunSubmissionError.invalidRequest }
        guard !reservations.contains(request.runID) else { throw ReadRunSubmissionError.conflict }
        guard reservations.count < maximumConcurrentRuns else { throw ReadRunSubmissionError.busy }
        let remaining = request.modelOptions.deadline.secondsSince1970-(try clock.now()).secondsSince1970
        guard remaining.isFinite,remaining > 0,request.budget.activeMilliseconds > 0 else { throw ReadRunSubmissionError.invalidRequest }
        let seconds = min(180,remaining,Double(request.budget.activeMilliseconds)/1000)
        let executionSeconds = max(1,Int(seconds.rounded(.up)))
        let binding = AGUIRunBinding(actorID:actorID,runID:request.runID,threadID:threadID,requestID:request.requestID)
        // Reserve before the first await: actor reentrancy cannot over-admit.
        reservations.insert(request.runID)
        var registered = false
        defer { if !registered { release(request.runID) } }
        let claim: any RunPublicationClaim
        do {
            let created = try await events.create(binding,retentionSeconds:retentionSeconds,deadline:.now.advanced(by:.seconds(4)))
            guard created.binding == binding else { throw RunEventStoreError.corruptRecord }
            try await tasks?.save(StoredReadRunTask(request:request,threadID:threadID),deadline:.now.advanced(by:.seconds(4)))
            claim = try await publication.claim(binding,maximumExecutionSeconds:executionSeconds,at:clock.now(),deadline:.now.advanced(by:.seconds(4)))
        } catch RunEventStoreError.conflict { throw ReadRunSubmissionError.conflict }
        catch { throw ReadRunSubmissionError.recoveryRequired }
        guard claim.binding == binding else { throw ReadRunSubmissionError.recoveryRequired }
        // A shutdown/cancel racing the claim must join publication, not dispatch.
        guard accepting,!Task.isCancelled,!cancellationRequests.contains(request.runID) else {
            await Self.publish(publication,claim:claim,outcome:.cancelled,clock:clock)
            throw accepting ? ReadRunSubmissionError.cancelled : .closed
        }
        let wallDeadline = min(request.modelOptions.deadline,claim.executionExpiresAt)
        let milliseconds = Int64(min(180_000,Double(request.budget.activeMilliseconds),max(0,(wallDeadline.secondsSince1970-(try clock.now()).secondsSince1970)*1000)).rounded(.down))
        guard milliseconds >= 1 else {
            await Self.publish(publication,claim:claim,outcome:.failed(.deadlineExceeded),clock:clock)
            return binding
        }
        let options = ReadPlanningOptions(preferredModelID:request.modelOptions.preferredModelID,cloudConsent:request.modelOptions.cloudConsent,
            allowFallback:request.modelOptions.allowFallback,maximumCostMicroUSD:request.modelOptions.maximumCostMicroUSD,
            maximumOutputTokens:request.modelOptions.maximumOutputTokens,deadline:wallDeadline)
        let bounded = ReadRunRequest(actorID:request.actorID,runID:request.runID,traceID:request.traceID,requestID:request.requestID,
            question:request.question,planningScope:request.planningScope,effectiveToolScope:request.effectiveToolScope,intent:request.intent,
            modelOptions:options,budget:request.budget)
        let deadline = ContinuousClock.now.advanced(by:.milliseconds(milliseconds))
        workers[request.runID] = Task { await self.work(bounded,claim:claim,deadline:deadline) }
        registered = true
        return binding
    }
    /// Signals only a locally owned execution. True acknowledges the request,
    /// not a terminal state: callers must read durable publication status.
    /// A completion already being published wins; no external rollback is implied.
    public func requestCancellation(actorID: UUID, runID: UUID) throws -> Bool {
        guard actorID == self.actorID else { throw ReadRunSubmissionError.invalidRequest }
        guard reservations.contains(runID) else { return false }
        cancellationRequests.insert(runID)
        workers[runID]?.cancel()
        return true
    }
    /// Explicitly await this before tearing down the database/client services.
    /// Includes submissions still awaiting their durable claim.
    public func shutdown() async {
        accepting = false
        for task in workers.values { task.cancel() }
        if !reservations.isEmpty { await withCheckedContinuation { shutdownWaiters.append($0) } }
    }
    private func work(_ request: ReadRunRequest, claim: any RunPublicationClaim, deadline: ContinuousClock.Instant) async {
        let outcome:RunPublicationOutcome
        do {
            let answer = try await withThrowingTaskGroup(of:GroundedAnswer.self) { group in
                group.addTask { try await self.executor.executeAnswer(request) }
                group.addTask { try await ContinuousClock().sleep(until:deadline);throw ReadRunFailureCode.deadlineExceeded }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw ReadRunFailureCode.recoveryRequired };return value
            }
            let allowedSubjects = Set(request.planningScope.entities.map(\.id))
            guard answer.actorId == request.actorID,answer.requestId == request.requestID,answer.intent == request.intent,
                  request.planningScope.allowGlobalChanges || (answer.claims.allSatisfy({ allowedSubjects.contains($0.subjectId) }) && answer.evidence.allSatisfy({ allowedSubjects.contains($0.subjectId) })) else { throw ReadRunFailureCode.invalidAnswer }
            outcome = .answer(answer,messageID:UUID())
        } catch {
            let code:ReadRunFailureCode
            if let failure = error as? ReadRunFailure { code = failure.code }
            else if let failure = error as? ReadRunFailureCode { code = failure }
            else if error is CancellationError { code = .cancelled }
            else { code = .recoveryRequired }
            switch code {
            case .cancelled: outcome = .cancelled
            case .deadlineExceeded: outcome = .failed(.deadlineExceeded)
            case .recoveryRequired: outcome = .failed(.recoveryRequired)
            default: outcome = .failed(.executionFailed)
            }
        }
        await Self.publish(publication,claim:claim,outcome:outcome,clock:clock)
        release(request.runID)
    }
    private static func publish(_ publication:any RunPublicationStore,claim:any RunPublicationClaim,outcome:RunPublicationOutcome,clock:any SquidraDomain.Clock) async {
        // Owned and awaited. A cancelled worker still joins bounded publication.
        // Ambiguous failure remains durable running/recovery state, never retry.
        let cleanup = Task {
            guard let at = try? clock.now() else { return }
            _ = try? await publication.finish(claim,outcome:outcome,at:at,deadline:.now.advanced(by:.seconds(4)))
        }
        await cleanup.value
    }
    private func release(_ runID: UUID) {
        workers.removeValue(forKey:runID);reservations.remove(runID);cancellationRequests.remove(runID)
        if reservations.isEmpty {
            let waiters = shutdownWaiters;shutdownWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
}
