import Foundation
import SquidraDomain
import SquidraTools
import XCTest
@testable import SquidraAgentRuntime

private struct RecoveryClock: SquidraDomain.Clock {
    let seconds: Double
    func now() throws -> UTCInstant { try UTCInstant(secondsSince1970:seconds) }
    func monotonicElapsed() -> Duration { .zero }
    func timezone() -> IANATimeZone { try! IANATimeZone(identifier:"UTC") }
}
private actor RecoveryRuns: RunStore {
    var value: RunSnapshot?
    var ambiguous = false
    func loseAcknowledgement() { ambiguous = true }
    func create(_ snapshot: RunSnapshot, deadline: ContinuousClock.Instant) { value = snapshot }
    func load(actorID: UUID, runID: UUID, deadline: ContinuousClock.Instant) throws -> RunSnapshot {
        guard let value,value.actorID == actorID,value.id == runID else { throw RunStoreError.notFound };return value
    }
    func compareAndSet(_ snapshot: RunSnapshot, expectedVersion: Int64, deadline: ContinuousClock.Instant) throws {
        guard let old = value,old.version == expectedVersion else { throw RunStoreError.conflict }
        guard !old.state.isTerminal else { throw RunStoreError.terminal }
        try snapshot.validate();value = snapshot
        if ambiguous { ambiguous = false;throw RunStoreError.unavailable }
    }
}
private actor RecoveryActions: ActionLedgerStore {
    var value: ActionRecord?
    func seed(_ record: ActionRecord) { value = record }
    func reserve(_ command: ActionCommand, deadline: ContinuousClock.Instant) throws -> ActionReservation { throw ActionLedgerError.unavailable }
    func load(actorID: UUID, id: UUID, deadline: ContinuousClock.Instant) throws -> ActionRecord {
        guard let value,value.id == id,value.command.actorID == actorID else { throw ActionLedgerError.notFound };return value
    }
    func update(_ record: ActionRecord, to status: ActionStatus, result: ActionResult?, providerReference: String?, deadline: ContinuousClock.Instant) throws -> ActionRecord {
        guard value?.version == record.version else { throw ActionLedgerError.versionConflict }
        let next = try ActionRecord(id:record.id,command:record.command,status:status,version:record.version+1,result:result,providerReference:providerReference)
        value = next;return next
    }
}
private actor RecoveryVerifier: RunEffectVerifier {
    let outcome: ActionResult?
    let unavailable: Bool
    var calls = 0
    init(_ outcome: ActionResult? = nil,unavailable:Bool = false) { self.outcome = outcome;self.unavailable = unavailable }
    func confirmedOutcome(for action: ActionRecord, deadline: ContinuousClock.Instant) throws -> ActionResult? { calls += 1;if unavailable { throw ActionLedgerError.unavailable };return outcome }
}
// SAFETY: independent actor-owned fixtures, no shared mutable test state.
final class RunRecoveryTests: XCTestCase, @unchecked Sendable {
    private func fixture() async throws -> (RunController,RecoveryRuns,RecoveryActions) {
        let runs = RecoveryRuns(),actions = RecoveryActions()
        let controller = try await RunController.create(actorID:UUID(),budget:RunBudget(activeMilliseconds:10_000),store:runs,clock:RecoveryClock(seconds:100))
        _ = try await controller.transition(to:.validating)
        _ = try await controller.transition(to:.contextLoading)
        _ = try await controller.transition(to:.planning)
        return (controller,runs,actions)
    }
    func testRecoveryChargesDowntimePreservesBudgetAndFencesStaleController() async throws {
        let (old,runs,actions) = try await fixture(),before = try await old.snapshot()
        let recovery = RunRecovery(runs:runs,actions:actions,verifier:RecoveryVerifier(),clock:RecoveryClock(seconds:103))
        guard case .ready(let restored) = try await recovery.recover(actorID:before.actorID,runID:before.id,expectedVersion:before.version) else { return XCTFail("No continuation") }
        let current = try await restored.snapshot()
        XCTAssertEqual(current.activeMilliseconds,3000);XCTAssertEqual(current.budget,before.budget)
        XCTAssertEqual(current.deadlineSecondsSince1970,before.deadlineSecondsSince1970)
        do { _ = try await old.validatedProposal(semanticDigest:String(repeating:"a",count:64));XCTFail("Stale controller wrote") }
        catch { XCTAssertEqual(error as? RunStoreError,.conflict) }
        _ = try await restored.validatedProposal(semanticDigest:String(repeating:"b",count:64))
    }
    func testExpiredCheckpointTerminatesAndClockRegressionDoesNotRenewBudget() async throws {
        for now in [99.0,111.0] {
            let (old,runs,actions) = try await fixture(),before = try await old.snapshot()
            let recovery = RunRecovery(runs:runs,actions:actions,verifier:RecoveryVerifier(),clock:RecoveryClock(seconds:now))
            if now < 100 {
                do { _ = try await recovery.recover(actorID:before.actorID,runID:before.id,expectedVersion:before.version);XCTFail("Wall regression accepted") }
                catch { XCTAssertEqual(error as? RunError,.clockRegression) }
            } else {
                guard case .terminal(let result) = try await recovery.recover(actorID:before.actorID,runID:before.id,expectedVersion:before.version) else { return XCTFail("Expired resumed") }
                XCTAssertEqual(result.state,.timedOut);XCTAssertEqual(result.activeMilliseconds,10_000)
            }
        }
    }
    func testUncertainEffectRequiresEvidenceAndNeverCreatesDispatchPermit() async throws {
        for scenario in 0..<3 {
            let confirmed = scenario == 1
            let (old,runs,actions) = try await fixture(),before = try await old.snapshot()
            let command = try ActionCommand(actorID:before.actorID,runID:before.id,tool:ToolID(namespace:"fixture",name:"write",version:"1.0.0"),idempotencyKey:"original-key",target:"entity:1",arguments:Data("{}".utf8),scope:["fixture:write"])
            _ = try await old.validatedProposal(semanticDigest:command.fingerprintHex,invocationKey:command.idempotencyKey)
            _ = try await old.transition(to:.executingTool)
            _ = try await old.reserveToolAttempt(timeoutMilliseconds:1000)
            let checkpoint = try await old.snapshot(),record = try ActionRecord(id:UUID(),command:command,status:.pending,version:1,result:nil,providerReference:nil)
            await actions.seed(record)
            let verifier = RecoveryVerifier(confirmed ? .failed(.notApplied) : nil,unavailable:scenario == 2)
            let recovery = RunRecovery(runs:runs,actions:actions,verifier:verifier,clock:RecoveryClock(seconds:101))
            let result = try await recovery.recover(actorID:before.actorID,runID:before.id,expectedVersion:checkpoint.version,actionID:record.id)
            if confirmed {
                guard case .ready(let restored) = result else { return XCTFail("Confirmed continuation missing") }
                let snapshot = try await restored.snapshot()
                XCTAssertEqual(snapshot.invocation?.key,"original-key");XCTAssertEqual(snapshot.calls,1)
                XCTAssertEqual(snapshot.invocation?.outcome,.failed);XCTAssertEqual(snapshot.invocation?.inFlight,false)
                _ = try await restored.finishIteration(progress:.none)
            } else {
                guard case .terminal(let snapshot) = result else { return XCTFail("Unknown effect resumed") }
                XCTAssertEqual(snapshot.terminalCode,.recoveryRequired);XCTAssertEqual(snapshot.invocation?.outcome,.unknown)
            }
            let calls = await verifier.calls;XCTAssertEqual(calls,1)
        }
    }
    func testReservedActionRetainsKeyAndRetryBudgetAndRejectsWrongBinding() async throws {
        for wrongBinding in [false,true] {
            let (old,runs,actions) = try await fixture(),initial = try await old.snapshot()
            let tool = try ToolID(namespace:"fixture",name:"write",version:"1.0.0")
            let command = try ActionCommand(actorID:initial.actorID,runID:initial.id,tool:tool,idempotencyKey:"stable-key",target:"entity:1",arguments:Data("{}".utf8),scope:[])
            _ = try await old.validatedProposal(semanticDigest:command.fingerprintHex,invocationKey:command.idempotencyKey)
            _ = try await old.transition(to:.executingTool)
            _ = try await old.reserveToolAttempt(timeoutMilliseconds:1000)
            let before = try await old.snapshot()
            let stored = try ActionCommand(actorID:initial.actorID,runID:wrongBinding ? UUID() : initial.id,tool:tool,idempotencyKey:"stable-key",target:"entity:1",arguments:Data("{}".utf8),scope:[])
            let record = try ActionRecord(id:UUID(),command:stored,status:.reserved,version:1,result:nil,providerReference:nil)
            await actions.seed(record)
            let verifier = RecoveryVerifier(),recovery = RunRecovery(runs:runs,actions:actions,verifier:verifier,clock:RecoveryClock(seconds:101))
            if wrongBinding {
                do { _ = try await recovery.recover(actorID:before.actorID,runID:before.id,expectedVersion:before.version,actionID:record.id);XCTFail("Foreign run evidence accepted") }
                catch { XCTAssertEqual(error as? RunError,.invalidCheckpoint) }
            } else {
                guard case .ready(let controller) = try await recovery.recover(actorID:before.actorID,runID:before.id,expectedVersion:before.version,actionID:record.id) else { return XCTFail("Unclaimed reservation not resumed") }
                let restored = try await controller.snapshot()
                XCTAssertEqual(restored.invocation?.key,"stable-key");XCTAssertEqual(restored.calls,1)
                XCTAssertEqual(restored.invocation?.attempts,1);XCTAssertEqual(restored.invocation?.outcome,.retryableFailure)
                do { _ = try await controller.reserveToolAttempt(timeoutMilliseconds:1000);XCTFail("Recovery bypassed retry backoff") }
                catch { XCTAssertEqual(error as? RunError,.retryBackoff) }
            }
            let verifications = await verifier.calls;XCTAssertEqual(verifications,0)
        }
    }
    func testApprovalWaitPreservesBudgetAndDoesNotConsultEffectVerifier() async throws {
        let (old,runs,actions) = try await fixture()
        _ = try await old.validatedProposal(semanticDigest:String(repeating:"a",count:64),invocationKey:"waiting-key")
        let waiting = try await old.transition(to:.waitingApproval,substate:.waitingApproval)
        let verifier = RecoveryVerifier(),recovery = RunRecovery(runs:runs,actions:actions,verifier:verifier,clock:RecoveryClock(seconds:10_000))
        guard case .waitingApproval(let snapshot) = try await recovery.recover(actorID:waiting.actorID,runID:waiting.id,expectedVersion:waiting.version) else { return XCTFail("Approval wait became executable") }
        XCTAssertEqual(snapshot,waiting)
        let calls = await verifier.calls;XCTAssertEqual(calls,0)
    }
    func testMissingLedgerEvidenceTerminatesWithoutResettingInvocation() async throws {
        let (old,runs,actions) = try await fixture()
        _ = try await old.validatedProposal(semanticDigest:String(repeating:"a",count:64),invocationKey:"original-key")
        _ = try await old.transition(to:.executingTool)
        _ = try await old.reserveToolAttempt(timeoutMilliseconds:1000)
        let before = try await old.snapshot()
        let recovery = RunRecovery(runs:runs,actions:actions,verifier:RecoveryVerifier(),clock:RecoveryClock(seconds:101))
        guard case .terminal(let snapshot) = try await recovery.recover(actorID:before.actorID,runID:before.id,expectedVersion:before.version) else { return XCTFail("Missing ledger evidence granted execution") }
        XCTAssertEqual(snapshot.terminalCode,.recoveryRequired);XCTAssertEqual(snapshot.calls,1)
        XCTAssertEqual(snapshot.invocation?.key,"original-key");XCTAssertEqual(snapshot.invocation?.attempts,1)
    }
    func testAmbiguousClaimReturnsNoContinuation() async throws {
        let (old,runs,actions) = try await fixture(),before = try await old.snapshot()
        await runs.loseAcknowledgement()
        let recovery = RunRecovery(runs:runs,actions:actions,verifier:RecoveryVerifier(),clock:RecoveryClock(seconds:101))
        do { _ = try await recovery.recover(actorID:before.actorID,runID:before.id,expectedVersion:before.version);XCTFail("Ambiguous recovery resumed") }
        catch { XCTAssertEqual(error as? RunStoreError,.unavailable) }
        do { _ = try await recovery.recover(actorID:before.actorID,runID:before.id,expectedVersion:before.version);XCTFail("Stale recovery repeated") }
        catch { XCTAssertEqual(error as? RunStoreError,.conflict) }
    }
}
