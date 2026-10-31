import Foundation
import SquidraDomain
import SquidraSecurity
import XCTest
@testable import SquidraAgentRuntime

private actor WaitRunStore: RunStore {
    private var value: RunSnapshot?
    func create(_ snapshot: RunSnapshot, deadline: ContinuousClock.Instant) throws {
        guard value == nil else { throw RunStoreError.conflict };value = snapshot
    }
    func load(actorID: UUID, runID: UUID, deadline: ContinuousClock.Instant) throws -> RunSnapshot {
        guard let value,value.actorID == actorID,value.id == runID else { throw RunStoreError.notFound };return value
    }
    func compareAndSet(_ snapshot: RunSnapshot, expectedVersion: Int64, deadline: ContinuousClock.Instant) throws {
        guard value?.version == expectedVersion else { throw RunStoreError.conflict };value = snapshot
    }
}
private actor WaitApprovalStore: ApprovalStore {
    private var record: ApprovalRecord
    init(_ record: ApprovalRecord) { self.record = record }
    func request(_ binding: ApprovalBinding, nowMilliseconds: Int64, ttlMilliseconds: Int64, deadline: ContinuousClock.Instant) throws -> ApprovalRecord {
        guard record.binding == binding else { throw ApprovalError.conflict };return record
    }
    func load(actorID: UUID, id: UUID, deadline: ContinuousClock.Instant) throws -> ApprovalObservation {
        guard record.binding.actorID == actorID,record.id == id else { throw ApprovalError.notFound }
        return ApprovalObservation(record:record,observedAtMilliseconds:record.requestedAtMilliseconds)
    }
    func resolve(_ value: ApprovalRecord, response: ApprovalResponse, approverID: UUID, nowMilliseconds: Int64, deadline: ContinuousClock.Instant) throws -> ApprovalRecord {
        guard value.version == record.version else { throw ApprovalError.conflict }
        record = try ApprovalRecord(id:record.id,binding:record.binding,requestedAtMilliseconds:record.requestedAtMilliseconds,
            expiresAtMilliseconds:record.expiresAtMilliseconds,decision:response.decision,approverID:approverID,decidedAtMilliseconds:nowMilliseconds,version:record.version+1)
        return record
    }
}

// SAFETY: no mutable suite state; persistence fixtures are actors.
final class ApprovalWaitTests: XCTestCase, @unchecked Sendable {
    private static let now: Int64 = 1_700_000_000_000
    private struct Fixture {
        let run: RunController, runs: WaitRunStore, approvals: WaitApprovalStore
        let service: ApprovalCoordinator, wait: ApprovalWait, record: ApprovalRecord
    }
    private static func clock(_ offset: Int64 = 0) throws -> FixedClock {
        try FixedClock(instant:UTCInstant(secondsSince1970:Double(now+offset)/1_000),timeZone:IANATimeZone(identifier:"Etc/UTC"))
    }
    private static func fixture() async throws -> Fixture {
        let actor = UUID(),id = UUID(),clock = try clock(),runs = WaitRunStore()
        let run = try await RunController.create(actorID:actor,id:id,store:runs,clock:clock)
        _ = try await run.transition(to:.validating);_ = try await run.transition(to:.planning)
        _ = try await run.validatedProposal(semanticDigest:String(repeating:"01",count:32),invocationKey:"sensitive-key")
        let binding = try ApprovalBinding(actorID:actor,runID:id,ledgerID:UUID(),commandHash:Data(repeating:1,count:32))
        let record = try ApprovalRecord(id:UUID(),binding:binding,requestedAtMilliseconds:now,expiresAtMilliseconds:now+600_000)
        let approvals = WaitApprovalStore(record),service = ApprovalCoordinator(store:approvals,clock:clock)
        return Fixture(run:run,runs:runs,approvals:approvals,service:service,wait:ApprovalWait(approvals:service,runs:runs,clock:clock),record:record)
    }
    private static func decide(_ fixture: Fixture, response: ApprovalResponse = .approve) async throws {
        _ = try await fixture.service.resolve(actorID:fixture.record.binding.actorID,id:fixture.record.id,response:response,
            principalID:fixture.record.binding.actorID,expectedDigest:fixture.record.digest,deadline:.now.advanced(by:.seconds(1)))
    }
    func testPendingWaitIsDurableAndReturnsWithoutHoldingWorker() async throws {
        let fixture = try await Self.fixture(),waiting = try await fixture.wait.suspend(fixture.run,for:fixture.record)
        XCTAssertEqual(waiting.state,.waitingApproval);XCTAssertNil(waiting.deadlineSecondsSince1970)
        guard case .waiting(let current) = try await fixture.wait.resume(actorID:waiting.actorID,approvalID:fixture.record.id,deadline:.now.advanced(by:.seconds(1))) else { return XCTFail("Pending did not remain waiting") }
        XCTAssertEqual(current.version,waiting.version);XCTAssertEqual(current.calls,0)
    }
    func testRestartWhileWaitingRevalidatesAndPreservesActiveBudget() async throws {
        let fixture = try await Self.fixture(),waiting = try await fixture.wait.suspend(fixture.run,for:fixture.record)
        try await Self.decide(fixture)
        let clock = try Self.clock(300_000),service = ApprovalCoordinator(store:fixture.approvals,clock:clock)
        let restarted = ApprovalWait(approvals:service,runs:fixture.runs,clock:clock)
        guard case .ready(let controller) = try await restarted.resume(actorID:waiting.actorID,approvalID:fixture.record.id,deadline:.now.advanced(by:.seconds(1))) else { return XCTFail("Approved continuation missing") }
        let snapshot = try await controller.snapshot()
        XCTAssertEqual(snapshot.state,.validating);XCTAssertEqual(snapshot.substate,.policyCheck)
        XCTAssertEqual(snapshot.activeMilliseconds,waiting.activeMilliseconds);XCTAssertEqual(snapshot.steps,waiting.steps);XCTAssertEqual(snapshot.calls,0)
        XCTAssertNotNil(snapshot.deadlineSecondsSince1970)
        do { _ = try await restarted.resume(actorID:waiting.actorID,approvalID:fixture.record.id,deadline:.now.advanced(by:.seconds(1)));XCTFail("Active continuation restored twice") }
        catch { XCTAssertEqual(error as? RunError,.recoveryRequired) }
    }
    func testDeniedWithdrawnAndExpiredApprovalsRefuseContinuation() async throws {
        for response in [ApprovalResponse.deny,.withdraw] {
            let fixture = try await Self.fixture();_ = try await fixture.wait.suspend(fixture.run,for:fixture.record)
            try await Self.decide(fixture,response:response)
            guard case .refused(let terminal) = try await fixture.wait.resume(actorID:fixture.record.binding.actorID,approvalID:fixture.record.id,deadline:.now.advanced(by:.seconds(1))) else { return XCTFail("Denied resumed") }
            XCTAssertEqual(terminal.state,.failed);XCTAssertEqual(terminal.terminalCode,.policyDenied);XCTAssertEqual(terminal.calls,0)
        }
        for approved in [false,true] {
            let fixture = try await Self.fixture();_ = try await fixture.wait.suspend(fixture.run,for:fixture.record)
            if approved { try await Self.decide(fixture) }
            let clock = try Self.clock(600_000),wait = ApprovalWait(approvals:ApprovalCoordinator(store:fixture.approvals,clock:clock),runs:fixture.runs,clock:clock)
            guard case .refused(let terminal) = try await wait.resume(actorID:fixture.record.binding.actorID,approvalID:fixture.record.id,deadline:.now.advanced(by:.seconds(1))) else { return XCTFail("Expired resumed") }
            XCTAssertEqual(terminal.terminalCode,.policyDenied);XCTAssertEqual(terminal.calls,0)
        }
    }
    func testDifferentCommandCannotSuspendTheCurrentRun() async throws {
        let fixture = try await Self.fixture(),binding = try ApprovalBinding(actorID:fixture.record.binding.actorID,runID:fixture.record.binding.runID,
            ledgerID:fixture.record.binding.ledgerID,commandHash:Data(repeating:2,count:32))
        let wrong = try ApprovalRecord(id:UUID(),binding:binding,requestedAtMilliseconds:Self.now,expiresAtMilliseconds:Self.now+600_000)
        do { _ = try await fixture.wait.suspend(fixture.run,for:wrong);XCTFail("Other proposal suspended") }
        catch { XCTAssertEqual(error as? ApprovalError,.conflict) }
        let forged = try ApprovalRecord(id:UUID(),binding:fixture.record.binding,requestedAtMilliseconds:Self.now,expiresAtMilliseconds:Self.now+600_000)
        do { _ = try await fixture.wait.suspend(fixture.run,for:forged);XCTFail("Nonpersisted request suspended run") }
        catch { XCTAssertEqual(error as? ApprovalError,.notFound) }
        let snapshot = try await fixture.run.snapshot();XCTAssertEqual(snapshot.state,.planning)
    }
}
