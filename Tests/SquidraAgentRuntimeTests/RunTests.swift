import Foundation
import Logging
import PostgresNIO
import SquidraDomain
@testable import SquidraPostgres
import XCTest
@testable import SquidraAgentRuntime

// SAFETY: every mutable field is read/written under this private NSLock.
private final class TestClock: SquidraDomain.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Int64 = 0
    private var wall: Int64 = 0
    func advance(_ milliseconds: Int64) { lock.withLock { elapsed += milliseconds; wall += milliseconds } }
    func moveWall(_ milliseconds: Int64) { lock.withLock { wall += milliseconds } }
    func rewindElapsed() { lock.withLock { elapsed = -1 } }
    func now() throws -> UTCInstant { try lock.withLock { try UTCInstant(secondsSince1970: Double(wall)/1_000) } }
    func timezone() -> IANATimeZone { try! IANATimeZone(identifier: "UTC") }
    func monotonicElapsed() -> Duration { lock.withLock { .milliseconds(elapsed) } }
}

private actor MemoryRuns: RunStore {
    private var values: [UUID:RunSnapshot] = [:]
    private var ambiguousWrite = false
    private var nextLatency: (TestClock, Int64)?
    func loseNextAcknowledgement() { ambiguousWrite = true }
    func delayNextWrite(clock: TestClock, milliseconds: Int64) { nextLatency = (clock, milliseconds) }
    func create(_ snapshot: RunSnapshot, deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard values[snapshot.id] == nil else { throw RunStoreError.conflict }
        values[snapshot.id] = snapshot
    }
    func load(actorID: UUID, runID: UUID, deadline: ContinuousClock.Instant) throws -> RunSnapshot {
        guard let value = values[runID], value.actorID == actorID else { throw RunStoreError.notFound }
        return value
    }
    func compareAndSet(_ snapshot: RunSnapshot, expectedVersion: Int64, deadline: ContinuousClock.Instant) throws {
        guard let current = values[snapshot.id], current.actorID == snapshot.actorID else { throw RunStoreError.notFound }
        guard current.version == expectedVersion else { throw RunStoreError.conflict }
        guard !current.state.isTerminal else { throw RunStoreError.terminal }
        values[snapshot.id] = snapshot
        if let (clock, duration) = nextLatency { nextLatency = nil; clock.advance(duration) }
        if ambiguousWrite { ambiguousWrite = false; throw RunStoreError.unavailable }
    }
}

// SAFETY: no mutable test-instance state. Remove when the runner supports Swift Testing.
final class RunPolicyTests: XCTestCase, @unchecked Sendable {
    private static func digest(_ value: Int = 1) -> String { String(format: "%064x", value) }
    private static func planning(clock: TestClock, store: MemoryRuns, budget: RunBudget = try! RunBudget()) async throws -> RunController {
        let run = try await RunController.create(actorID: UUID(), budget: budget, store: store, clock: clock)
        _ = try await run.transition(to: .validating)
        _ = try await run.transition(to: .contextLoading)
        _ = try await run.transition(to: .planning)
        return run
    }
    private static func tool(clock: TestClock, store: MemoryRuns, budget: RunBudget = try! RunBudget()) async throws -> RunController {
        let run = try await planning(clock: clock, store: store, budget: budget)
        _ = try await run.validatedProposal(semanticDigest: digest(), invocationKey: "same-invocation")
        _ = try await run.transition(to: .executingTool)
        return run
    }

    func testCompletePublicTransitionMatrix() {
        let expected: [RunState:Set<RunState>] = [
            .created:[.validating], .validating:[.contextLoading,.planning,.waitingApproval,.executingTool,.responding],
            .contextLoading:[.planning], .planning:[.validating,.waitingApproval,.executingTool,.responding],
            .waitingApproval:[.validating], .executingTool:[.planning,.responding], .responding:[.planning,.completed],
        ]
        let failureExits: Set<RunState> = [.failed,.cancelled,.timedOut,.budgetExceeded]
        XCTAssertEqual(RunState.allCases.count, 12)
        for source in RunState.allCases {
            for target in RunState.allCases {
                let allowed = source.isTerminal ? false : (expected[source,default:[]].union(failureExits).contains(target))
                XCTAssertEqual(source.permits(target), allowed, "\(source) -> \(target)")
            }
        }
        for substate in RunSubstate.allCases { XCTAssertFalse(substate.publicState.isTerminal) }
    }

    func testValidatedResponseCompletesAndTerminalCannotResume() async throws {
        let run = try await Self.planning(clock: TestClock(), store: MemoryRuns())
        _ = try await run.validatedProposal(semanticDigest: Self.digest())
        _ = try await run.transition(to: .responding, substate: .responding)
        _ = try await run.finishIteration(progress: .newEvidence)
        let final = try await run.transition(to: .completed, terminalCode: .completed)
        XCTAssertEqual(final.state, .completed); XCTAssertEqual(final.steps, 1)
        XCTAssertNil(final.deadlineSecondsSince1970)
        do { _ = try await run.transition(to: .planning); XCTFail("Terminal resumed") }
        catch { XCTAssertEqual(error as? RunError, .terminal) }
    }

    func testInvalidTransitionsAndUnvalidatedDispatchAreRejected() async throws {
        let clock = TestClock(), store = MemoryRuns()
        let run = try await RunController.create(actorID: UUID(), store: store, clock: clock)
        do { _ = try await run.transition(to: .executingTool); XCTFail("Illegal transition") }
        catch { XCTAssertEqual(error as? RunError, .invalidTransition) }
        let planner = try await Self.planning(clock: clock, store: store)
        do { _ = try await planner.transition(to: .executingTool); XCTFail("Unvalidated dispatch") }
        catch { XCTAssertEqual(error as? RunError, .invalidProposal) }
        do { _ = try await planner.transition(to: .validating, substate: .executing); XCTFail("Substate mismatch") }
        catch { XCTAssertEqual(error as? RunError, .invalidTransition) }
    }

    func testTwentyValidatedStepsThenExplicitStepLimit() async throws {
        let run = try await Self.planning(clock: TestClock(), store: MemoryRuns())
        for index in 0..<20 {
            _ = try await run.validatedProposal(semanticDigest: Self.digest(index))
            _ = try await run.finishIteration(progress: .newEvidence)
        }
        let result = try await run.validatedProposal(semanticDigest: Self.digest(21))
        XCTAssertEqual(result.steps, 20); XCTAssertEqual(result.state, .budgetExceeded)
        XCTAssertEqual(result.terminalCode, .stepLimit)
    }

    func testFifteenAttemptsThenNoSixteenthPermit() async throws {
        let run = try await Self.planning(clock: TestClock(), store: MemoryRuns())
        for index in 0..<15 {
            _ = try await run.validatedProposal(semanticDigest: Self.digest(index), invocationKey: "invocation-\(index)")
            _ = try await run.transition(to: .executingTool)
            let permit = try await run.reserveToolAttempt(timeoutMilliseconds: 1_000)
            XCTAssertNotNil(permit)
            _ = try await run.finishToolAttempt(.confirmed)
            _ = try await run.finishIteration(progress: .confirmedEffect)
            _ = try await run.transition(to: .planning)
        }
        _ = try await run.validatedProposal(semanticDigest: Self.digest(16), invocationKey: "sixteenth")
        _ = try await run.transition(to: .executingTool)
        let permit = try await run.reserveToolAttempt(timeoutMilliseconds: 1_000)
        XCTAssertNil(permit)
        let snapshot = try await run.snapshot()
        XCTAssertEqual(snapshot.calls, 15); XCTAssertEqual(snapshot.terminalCode, .callLimit)
    }

    func testDepthThreeAllowedAndFourTerminatesBeforeProposal() async throws {
        let run = try await Self.planning(clock: TestClock(), store: MemoryRuns())
        _ = try await run.validatedProposal(semanticDigest: Self.digest(), delegationDepth: 3)
        _ = try await run.finishIteration(progress: .newEvidence)
        let result = try await run.validatedProposal(semanticDigest: Self.digest(2), delegationDepth: 4)
        XCTAssertEqual(result.maximumDelegationDepth, 3); XCTAssertEqual(result.steps, 1)
        XCTAssertEqual(result.terminalCode, .depthLimit)
    }

    func testTwoRetriesBackoffSameKeyAndAttemptAccounting() async throws {
        let clock = TestClock(), run = try await Self.tool(clock: clock, store: MemoryRuns())
        var permits: [ToolAttemptPermit] = []
        for ordinal in 0...2 {
            if ordinal > 0 {
                do { _ = try await run.reserveToolAttempt(timeoutMilliseconds: 2_000); XCTFail("Retry bypassed backoff") }
                catch { XCTAssertEqual(error as? RunError, .retryBackoff) }
                clock.advance(ordinal == 1 ? 500 : 1_000)
            }
            let granted = try await run.reserveToolAttempt(timeoutMilliseconds: 2_000)
            let permit = try XCTUnwrap(granted)
            permits.append(permit)
            XCTAssertEqual(permit.retryOrdinal, ordinal)
            _ = try await run.finishToolAttempt(.retryableFailure)
        }
        clock.advance(1_000)
        let extra = try await run.reserveToolAttempt(timeoutMilliseconds: 2_000)
        XCTAssertNil(extra)
        XCTAssertEqual(Set(permits.map(\.idempotencyKey)), ["same-invocation"])
        let snapshot = try await run.snapshot()
        XCTAssertEqual(snapshot.calls, 3); XCTAssertEqual(snapshot.terminalCode, .retryLimit)
    }

    func testUnknownOutcomeCannotBeBlindlyRetried() async throws {
        let clock = TestClock(), run = try await Self.tool(clock: clock, store: MemoryRuns())
        _ = try await run.reserveToolAttempt(timeoutMilliseconds: 1_000)
        _ = try await run.finishToolAttempt(.unknown)
        clock.advance(1_000)
        do { _ = try await run.reserveToolAttempt(timeoutMilliseconds: 1_000); XCTFail("Unknown replayed") }
        catch { XCTAssertEqual(error as? RunError, .reconciliationRequired) }
    }

    func testRejectedProposalsAndNewKeysCannotEvadeThreeRepetitions() async throws {
        let rejected = try await Self.planning(clock: TestClock(), store: MemoryRuns())
        for _ in 0..<3 { _ = try await rejected.rejectedProposal(semanticDigest: Self.digest()) }
        let rejection = try await rejected.snapshot()
        XCTAssertEqual(rejection.steps, 0); XCTAssertEqual(rejection.terminalCode, .loopDetected)
        let validated = try await Self.planning(clock: TestClock(), store: MemoryRuns())
        for _ in 0..<3 {
            _ = try await validated.validatedProposal(semanticDigest: Self.digest(), invocationKey: UUID().uuidString)
            _ = try await validated.finishIteration(progress: .none)
        }
        let result = try await validated.snapshot()
        XCTAssertEqual(result.steps, 3); XCTAssertEqual(result.noProgressRepetitions, 3)
        XCTAssertEqual(result.state, .budgetExceeded); XCTAssertEqual(result.terminalCode, .loopDetected)
    }

    func testVerifiedProgressResetsButBookkeepingDoesNot() async throws {
        let run = try await Self.planning(clock: TestClock(), store: MemoryRuns())
        for _ in 0..<2 { _ = try await run.rejectedProposal(semanticDigest: Self.digest()) }
        _ = try await run.validatedProposal(semanticDigest: Self.digest())
        _ = try await run.transition(to: .responding)
        let result = try await run.finishIteration(progress: .newEvidence)
        XCTAssertEqual(result.noProgressRepetitions, 0)
        _ = try await run.transition(to: .planning)
        _ = try await run.rejectedProposal(semanticDigest: Self.digest())
        let next = try await run.rejectedProposal(semanticDigest: Self.digest())
        XCTAssertEqual(next.noProgressRepetitions, 2); XCTAssertEqual(next.state, .planning)
    }

    func testMonotonicBudgetIgnoresWallClockSkewAndBoundsPermit() async throws {
        let clock = TestClock(), run = try await Self.tool(clock: clock, store: MemoryRuns(), budget: RunBudget(activeMilliseconds: 100))
        clock.moveWall(86_400_000)
        clock.advance(60)
        let permit = try await run.reserveToolAttempt(timeoutMilliseconds: 80)
        XCTAssertEqual(permit?.timeoutMilliseconds, 40)
        clock.advance(40)
        let result = try await run.finishToolAttempt(.confirmed)
        XCTAssertEqual(result.state, .timedOut); XCTAssertEqual(result.activeMilliseconds, 100)
    }

    func testDefault180SecondActiveBudgetTerminatesExplicitly() async throws {
        let clock = TestClock(), run = try await Self.planning(clock: clock, store: MemoryRuns())
        clock.advance(180_000)
        let result = try await run.validatedProposal(semanticDigest: Self.digest())
        XCTAssertEqual(result.state, .timedOut)
        XCTAssertEqual(result.terminalCode, .timedOut)
        XCTAssertEqual(result.steps, 0)
    }

    func testApprovalWaitExcludesElapsedTimeAndResumeIsExplicit() async throws {
        let clock = TestClock(), store = MemoryRuns(), run = try await Self.planning(clock: clock, store: store)
        _ = try await run.validatedProposal(semanticDigest: Self.digest(), invocationKey: "approval")
        clock.advance(100)
        let waiting = try await run.transition(to: .waitingApproval, substate: .waitingApproval)
        XCTAssertEqual(waiting.activeMilliseconds, 100); XCTAssertNil(waiting.deadlineSecondsSince1970)
        clock.advance(600_000)
        let restored = try await RunController.restoreWaiting(actorID: waiting.actorID, id: waiting.id, store: store, clock: clock)
        let resumed = try await restored.transition(to: .validating, substate: .policyCheck)
        XCTAssertEqual(resumed.activeMilliseconds, 100)
        XCTAssertNotNil(resumed.deadlineSecondsSince1970)
        _ = try await restored.transition(to: .executingTool)
        clock.advance(50)
        let permit = try await restored.reserveToolAttempt(timeoutMilliseconds: 1_000)
        XCTAssertNotNil(permit)
        let active = try await restored.snapshot()
        XCTAssertEqual(active.activeMilliseconds, 150)
    }

    func testActiveAndTerminalRecordsNeverImplicitlyReattach() async throws {
        let clock = TestClock(), store = MemoryRuns(), run = try await Self.planning(clock: clock, store: store)
        let active = try await run.snapshot()
        do { _ = try await RunController.restoreWaiting(actorID: active.actorID, id: active.id, store: store, clock: clock); XCTFail("Active resumed") }
        catch { XCTAssertEqual(error as? RunError, .recoveryRequired) }
        let terminal = try await run.transition(to: .failed, terminalCode: .policyDenied)
        XCTAssertEqual(terminal.terminalCode, .policyDenied)
        do { _ = try await RunController.restoreWaiting(actorID: active.actorID, id: active.id, store: store, clock: clock); XCTFail("Terminal resumed") }
        catch { XCTAssertEqual(error as? RunError, .terminal) }
    }

    func testBudgetTerminalReasonsCannotBeForgedWithoutExhaustion() async throws {
        let run = try await Self.planning(clock: TestClock(), store: MemoryRuns())
        for (state, code) in [(RunState.timedOut, RunTerminalCode.timedOut), (.budgetExceeded, .stepLimit)] {
            do { _ = try await run.transition(to: state, terminalCode: code); XCTFail("Unexhausted budget terminal accepted") }
            catch { XCTAssertEqual(error as? RunError, .invalidTransition) }
        }
    }

    func testDurableWaitCannotFinishItsPendingIteration() async throws {
        let run = try await Self.planning(clock: TestClock(), store: MemoryRuns())
        _ = try await run.validatedProposal(semanticDigest: Self.digest(), invocationKey: "wait")
        _ = try await run.transition(to: .waitingApproval)
        do { _ = try await run.finishIteration(progress: .newEvidence); XCTFail("Wait bypassed revalidation") }
        catch { XCTAssertEqual(error as? RunError, .invalidProposal) }
    }

    func testLostWriteAcknowledgementDetachesController() async throws {
        let clock = TestClock(), store = MemoryRuns(), run = try await Self.planning(clock: clock, store: store)
        let before = try await run.snapshot()
        await store.loseNextAcknowledgement()
        do { _ = try await run.validatedProposal(semanticDigest: Self.digest()); XCTFail("Lost acknowledgement accepted") }
        catch { XCTAssertEqual(error as? RunStoreError, .unavailable) }
        do { _ = try await run.snapshot(); XCTFail("Unconfirmed state exposed") }
        catch { XCTAssertEqual(error as? RunError, .recoveryRequired) }
        let authoritative = try await store.load(actorID: before.actorID, runID: before.id, deadline: .now.advanced(by: .seconds(1)))
        XCTAssertEqual(authoritative.version, before.version+1)
    }

    func testStorageLatencyCanExhaustBudgetBeforeDispatch() async throws {
        let clock = TestClock(), store = MemoryRuns(), run = try await Self.tool(clock: clock, store: store, budget: RunBudget(activeMilliseconds: 10))
        await store.delayNextWrite(clock: clock, milliseconds: 11)
        let permit = try await run.reserveToolAttempt(timeoutMilliseconds: 10)
        XCTAssertNil(permit)
        let result = try await run.snapshot()
        XCTAssertEqual(result.state, .timedOut); XCTAssertEqual(result.calls, 1)
    }

    func testClockRegressionAndRaisedBudgetsAreRejected() async throws {
        let clock = TestClock(), run = try await Self.planning(clock: clock, store: MemoryRuns())
        clock.rewindElapsed()
        do { _ = try await run.validatedProposal(semanticDigest: Self.digest()); XCTFail("Regressed clock accepted") }
        catch { XCTAssertEqual(error as? RunError, .clockRegression) }
        XCTAssertThrowsError(try RunBudget(steps: 21)); XCTAssertThrowsError(try RunBudget(calls: 16))
        XCTAssertThrowsError(try RunBudget(depth: 4)); XCTAssertThrowsError(try RunBudget(retries: 3))
        XCTAssertThrowsError(try RunBudget(activeMilliseconds: 180_001))
    }
}

// SAFETY: no mutable test-instance state; owns a disposable database fixture.
final class RunSQLTests: XCTestCase, @unchecked Sendable {
    private static let logger = Logger(label: "squidra.runtime-test", factory: { _ in SwiftLogNoOpLogHandler() })
    private static func waiting(store: any RunStore, clock: TestClock, repetitions: Int = 0) async throws -> RunSnapshot {
        let run = try await RunController.create(actorID: UUID(), store: store, clock: clock)
        _ = try await run.transition(to: .validating)
        _ = try await run.transition(to: .contextLoading)
        _ = try await run.transition(to: .planning)
        let digest = String(repeating: "a", count: 64)
        for _ in 0..<repetitions { _ = try await run.rejectedProposal(semanticDigest: digest) }
        _ = try await run.validatedProposal(semanticDigest: digest, invocationKey: "persisted-key")
        clock.advance(100)
        return try await run.transition(to: .waitingApproval, substate: .waitingApproval)
    }
    private static func resume(_ controller: RunController) async throws -> Bool {
        do { _ = try await controller.transition(to: .validating); return true }
        catch RunStoreError.conflict { return false }
    }

    func testDurableCheckpointFreshClientCASActorIsolationAndTerminalGuards() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["SQUIDRA_TEST_DB_PORT"], let port = Int(text), let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            XCTFail("Run SQD-005 through its isolated real database helper"); return
        }
        let config = try LocalDatabaseConfiguration(port: port, username: "squidra", password: password, database: "squidra")
        let clock = TestClock(), firstClient = config.makeClient()
        let saved = try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await firstClient.run() }
            defer { group.cancelAll() }
            return try await Self.waiting(store: PostgresRunStore(client: firstClient), clock: clock, repetitions: 2)
        }
        // The first pool has shut down. Reload via a distinct client and adapter.
        let secondClient = config.makeClient()
        let durable = PostgresRunStore(client: secondClient)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await secondClient.run() }
            defer { group.cancelAll() }
            let loaded = try await durable.load(actorID: saved.actorID, runID: saved.id, deadline: .now.advanced(by: .seconds(2)))
            XCTAssertEqual(loaded, saved)
            XCTAssertEqual(loaded.noProgressRepetitions, 2)
            do { _ = try await durable.load(actorID: UUID(), runID: saved.id, deadline: .now.advanced(by: .seconds(2))); XCTFail("Actor boundary bypassed") }
            catch { XCTAssertEqual(error as? RunStoreError, .notFound) }
            clock.advance(600_000)
            let restored = try await RunController.restoreWaiting(actorID: saved.actorID, id: saved.id, store: durable, clock: clock)
            let resumed = try await restored.transition(to: .validating)
            XCTAssertEqual(resumed.activeMilliseconds, 100)
            let loop = try await restored.finishIteration(progress: .none)
            XCTAssertEqual(loop.terminalCode, .loopDetected)
            var forged = loop
            forged.version += 1; forged.state = .validating; forged.terminalCode = nil
            forged.noProgressRepetitions = 0; forged.lastNoProgressIteration = nil
            do { try await durable.compareAndSet(forged, expectedVersion: loop.version, deadline: .now.advanced(by: .seconds(2))); XCTFail("Terminal overwritten") }
            catch { XCTAssertEqual(error as? RunStoreError, .terminal) }

            let pending = try await Self.waiting(store: durable, clock: clock)
            let a = try await RunController.restoreWaiting(actorID: pending.actorID, id: pending.id, store: durable, clock: clock)
            let b = try await RunController.restoreWaiting(actorID: pending.actorID, id: pending.id, store: durable, clock: clock)
            let results = try await secondClient.withConnection(isolation: nil) { blocker in
                var transactionOpen = true
                defer { if transactionOpen { blocker.close().whenFailure { _ in } } }
                _ = try await blocker.query("BEGIN", logger: Self.logger).collect()
                _ = try await blocker.query("SELECT id FROM agent_runs WHERE id=\(pending.id) FOR UPDATE", logger: Self.logger).collect()
                async let first = Self.resume(a)
                async let second = Self.resume(b)
                // Prove both real SQL sessions overlap behind the held row lock.
                let limit = ContinuousClock.now.advanced(by: .seconds(1))
                var blocked: Int64 = 0
                repeat {
                    let rows = try await secondClient.query("SELECT count(*)::bigint FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%FROM agent_runs%'").collect()
                    blocked = try rows[0].decode(Int64.self)
                    if blocked >= 2 { break }
                    try await Task.sleep(for: .milliseconds(10))
                } while ContinuousClock.now < limit
                XCTAssertGreaterThanOrEqual(blocked, 2)
                _ = try await blocker.query("ROLLBACK", logger: Self.logger).collect()
                transactionOpen = false
                return try await (first, second)
            }
            XCTAssertNotEqual(results.0, results.1)
            let winner = results.0 ? a : b
            let cancelled = try await winner.transition(to: .cancelled, terminalCode: .cancelled)
            let terminal = try await durable.load(actorID: pending.actorID, runID: pending.id, deadline: .now.advanced(by: .seconds(2)))
            XCTAssertEqual(terminal, cancelled)

            // Deterministic regression: closed channels fail without an
            // unresumed SQL promise, even before a query has been enqueued.
            try await secondClient.withConnection(isolation: nil) { closed in
                try await closed.close()
                do { _ = try await BoundedPostgresQuery.rows(closed, "SELECT 1"); XCTFail("Closed query accepted") }
                catch PostgresTransportError.closed {} // expected
            }

            let corrupt = try await RunController.create(actorID: UUID(), store: durable, clock: clock)
            let original = try await corrupt.snapshot()
            _ = try await secondClient.query("UPDATE agent_runs SET version=version+1, checkpoint=jsonb_set(checkpoint,'{schemaVersion}','99') WHERE id=\(original.id)").collect()
            do { _ = try await durable.load(actorID: original.actorID, runID: original.id, deadline: .now.advanced(by: .seconds(2))); XCTFail("Corrupt checkpoint accepted") }
            catch { XCTAssertEqual(error as? RunStoreError, .corruptCheckpoint) }
        }
    }
}
