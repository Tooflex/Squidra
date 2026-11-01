import Foundation
import XCTest
@testable import SquidraAgentRuntime

private struct Worker: DelegationExecuting {
    let body: @Sendable (DelegationTask, DelegationContext) async throws -> String
    func execute(_ task: DelegationTask, context: DelegationContext) async throws -> String { try await body(task, context) }
}
private actor Probe {
    var calls = 0
    var stopped = false
    var saved: DelegationContext?
    func call() { calls += 1 }
    func stop() { stopped = true }
    func save(_ context: DelegationContext) { saved = context }
}

final class DelegationTests: XCTestCase, @unchecked Sendable {
    private func budget(_ steps: Int = 10, calls: Int = 5, tokens: Int = 100,
                        cost: Int64 = 100, ms: Int64 = 1000) throws -> DelegationBudget {
        try DelegationBudget(steps: steps, calls: calls, tokens: tokens, costMicroUSD: cost, milliseconds: ms)
    }
    private func root(grants: Set<DelegationGrant>, budget: DelegationBudget) throws -> DelegationContext {
        try .root(actorID: UUID(), runID: UUID(), traceID: UUID(), grants: grants, budget: budget)
    }
    private func rejects(_ expected: DelegationError, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? DelegationError, expected) }
    }

    func testExplicitScopeResultCorrelationAndClosedChild() async throws {
        let read = try DelegationGrant(capability: "world:read", resourceID: UUID())
        let parent = try root(grants: [read], budget: budget())
        let probe = Probe()
        let task = try DelegationTask(instruction: "Read a bounded fixture", grants: [read], budget: budget(2, calls: 1, ms: 100))
        let result = try await parent.delegate(task, to: Worker { task, child in
            XCTAssertEqual(task.grants, [read]); await probe.save(child)
            return try await child.perform(grant: read, tokens: 5, costMicroUSD: 2) { _ in
                await probe.call(); return "fixture result"
            }
        })
        XCTAssertEqual(result.output, "fixture result")
        XCTAssertEqual(result.trace.outcome, .completed)
        XCTAssertEqual(result.trace.actorID, parent.actorID)
        XCTAssertEqual(result.trace.traceID, parent.traceID)
        XCTAssertEqual(result.trace.rootRunID, parent.rootRunID)
        XCTAssertEqual(result.trace.parentRunID, parent.rootRunID)
        XCTAssertNotEqual(result.trace.childRunID, parent.rootRunID)
        XCTAssertEqual(result.trace.depth, 1)
        let count = await probe.calls; XCTAssertEqual(count, 1)
        let saved = await probe.saved!
        await rejects(.closed) { _ = try await saved.perform(grant: read, tokens: 0, costMicroUSD: 0) { _ in "invalid" } }
        let traceJSON = String(decoding: try JSONEncoder().encode(result.trace), as: UTF8.self)
        XCTAssertFalse(traceJSON.contains("fixture"))
    }

    func testNoImplicitScopeAndNoCrossProductEscalation() async throws {
        let a = UUID(), b = UUID()
        let readA = try DelegationGrant(capability: "read", resourceID: a)
        let writeB = try DelegationGrant(capability: "write", resourceID: b)
        let writeA = try DelegationGrant(capability: "write", resourceID: a)
        let parent = try root(grants: [readA, writeB], budget: budget())
        let never = Worker { _, _ in XCTFail("must not dispatch"); return "" }
        await rejects(.denied) {
            _ = try await parent.delegate(DelegationTask(instruction: "escalate", grants: [writeA], budget: budget(1)), to: never)
        }
        let task = try DelegationTask(instruction: "no inherited grant", grants: [], budget: budget(2, ms: 100))
        let result = try await parent.delegate(task, to: Worker { _, child in
            try await child.perform(grant: readA, tokens: 0, costMicroUSD: 0) { _ in XCTFail("denied"); return "" }
        })
        XCTAssertEqual(result.trace.outcome, .denied); XCTAssertNil(result.output)
    }

    func testEveryBudgetDimensionRejectsBeforeDispatch() async throws {
        let parent = try root(grants: [], budget: budget(3, calls: 1, tokens: 2, cost: 3, ms: 1000))
        let variants = [try budget(3, calls: 0, tokens: 0, cost: 0, ms: 1),
                        try budget(1, calls: 2, tokens: 0, cost: 0, ms: 1),
                        try budget(1, calls: 0, tokens: 3, cost: 0, ms: 1),
                        try budget(1, calls: 0, tokens: 0, cost: 4, ms: 1),
                        try budget(1, calls: 0, tokens: 0, cost: 0, ms: 1001)]
        for b in variants {
            await rejects(.budgetExceeded) {
                _ = try await parent.delegate(DelegationTask(instruction: "too large", grants: [], budget: b),
                    to: Worker { _, _ in XCTFail("no dispatch"); return "" })
            }
        }
    }

    func testConcurrentChildrenCannotOversubscribeAndFailureDoesNotRefund() async throws {
        let parent = try root(grants: [], budget: budget(3, calls: 1))
        let task = try DelegationTask(instruction: "reserve", grants: [], budget: budget(2, calls: 1, ms: 100))
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    do {
                        let r = try await parent.delegate(task, to: Worker { _, _ in throw DelegationError.invalidContract })
                        return r.trace.outcome == .failed
                    } catch { return false }
                }
            }
            var accepted = 0
            for await value in group where value { accepted += 1 }
            return accepted
        }
        XCTAssertEqual(results, 1)
        await rejects(.budgetExceeded) { _ = try await parent.delegate(task, to: Worker { _, _ in "retry" }) }
    }

    func testDepthThreeAcceptedFourRejectedWithImmediateParentCorrelation() async throws {
        let parent = try root(grants: [], budget: budget(10, calls: 0, tokens: 0, cost: 0))
        let b1 = try budget(8, calls: 0, tokens: 0, cost: 0, ms: 800)
        let b2 = try budget(6, calls: 0, tokens: 0, cost: 0, ms: 600)
        let b3 = try budget(4, calls: 0, tokens: 0, cost: 0, ms: 400)
        let b4 = try budget(2, calls: 0, tokens: 0, cost: 0, ms: 200)
        let leaf = Worker { _, child in
            XCTAssertEqual(child.depth, 3)
            do {
                _ = try await child.delegate(DelegationTask(instruction: "four", grants: [], budget: b4),
                    to: Worker { _, _ in XCTFail("depth four"); return "" })
                XCTFail("depth guard")
            } catch { XCTAssertEqual(error as? DelegationError, .depthExceeded) }
            return "three"
        }
        let second = Worker { _, child in
            let result = try await child.delegate(DelegationTask(instruction: "three", grants: [], budget: b3), to: leaf)
            XCTAssertEqual(result.trace.depth, 3); XCTAssertEqual(result.trace.traceID, parent.traceID)
            XCTAssertEqual(result.trace.outcome, .completed)
            return result.trace.parentRunID.uuidString
        }
        let first = Worker { _, child in
            let result = try await child.delegate(DelegationTask(instruction: "two", grants: [], budget: b2), to: second)
            XCTAssertEqual(result.output, result.trace.childRunID.uuidString)
            return "ok"
        }
        let result = try await parent.delegate(DelegationTask(instruction: "one", grants: [], budget: b1), to: first)
        XCTAssertEqual(result.trace.outcome, .completed)
    }

    func testAttemptsChargeBeforeFailureAndCannotReuseBudget() async throws {
        let grant = try DelegationGrant(capability: "read", resourceID: UUID())
        let parent = try root(grants: [grant], budget: budget(2, calls: 1, tokens: 10, cost: 10))
        let probe = Probe()
        do {
            _ = try await parent.perform(grant: grant, tokens: 10, costMicroUSD: 10) { _ -> String in
                await probe.call(); throw DelegationError.invalidContract
            }
        } catch { XCTAssertEqual(error as? DelegationError, .invalidContract) }
        await rejects(.budgetExceeded) {
            _ = try await parent.perform(grant: grant, tokens: 0, costMicroUSD: 0) { _ in await probe.call(); return "retry" }
        }
        let count = await probe.calls; XCTAssertEqual(count, 1)
    }

    func testDeadlineAndCancellationJoinChildAndSanitizeFailures() async throws {
        let sleeping = Probe()
        let worker = Worker { _, _ in
            await sleeping.call()
            do { try await Task.sleep(for: .seconds(5)) }
            catch { await sleeping.stop(); throw error }
            return "late"
        }
        let parent = try root(grants: [], budget: budget())
        let short = try DelegationTask(instruction: "deadline", grants: [], budget: budget(1, calls: 0, tokens: 0, cost: 0, ms: 30))
        let timed = try await parent.delegate(short, to: worker)
        XCTAssertEqual(timed.trace.outcome, .timedOut); XCTAssertNil(timed.output)
        let stopped = await sleeping.stopped; XCTAssertTrue(stopped)

        let cancelledProbe = Probe()
        let task = try DelegationTask(instruction: "cancel", grants: [], budget: budget(1, calls: 0, tokens: 0, cost: 0, ms: 500))
        let running = Task { try await parent.delegate(task, to: Worker { _, _ in
            await cancelledProbe.call()
            do { try await Task.sleep(for: .seconds(5)) }
            catch { await cancelledProbe.stop(); throw error }
            return "late"
        }) }
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await cancelledProbe.calls == 0, ContinuousClock.now < startDeadline { await Task.yield() }
        running.cancel()
        let result = try await running.value
        XCTAssertEqual(result.trace.outcome, .cancelled)
        let joined = await cancelledProbe.stopped; XCTAssertTrue(joined)

        let fresh = try root(grants: [], budget: budget())
        let bad = try await fresh.delegate(short, to: Worker { _, _ in throw NSError(domain: "SECRET", code: 1) })
        XCTAssertEqual(bad.trace.outcome, .failed); XCTAssertNil(bad.output)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(bad.trace), as: UTF8.self).contains("SECRET"))
    }

    func testContractBoundsAndParentClose() async throws {
        XCTAssertThrowsError(try budget(21))
        XCTAssertThrowsError(try budget(tokens: -1))
        XCTAssertThrowsError(try DelegationGrant(capability: "read write", resourceID: UUID()))
        XCTAssertThrowsError(try DelegationTask(instruction: "", grants: [], budget: budget()))
        let parent = try root(grants: [], budget: budget())
        let task = try DelegationTask(instruction: "bounded output", grants: [], budget: budget(1, ms: 100))
        let result = try await parent.delegate(task, to: Worker { _, _ in String(repeating: "x", count: 16_385) })
        XCTAssertEqual(result.trace.outcome, .failed); XCTAssertNil(result.output)
        await parent.close()
        await rejects(.closed) { _ = try await parent.delegate(task, to: Worker { _, _ in "closed" }) }
    }
}
