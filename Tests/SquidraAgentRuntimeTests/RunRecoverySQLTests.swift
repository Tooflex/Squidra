import Foundation
import PostgresNIO
import SquidraDomain
import SquidraPostgres
import SquidraTools
import XCTest
@testable import SquidraAgentRuntime

private struct RecoverySQLClock: SquidraDomain.Clock {
    let start = ContinuousClock.now
    func now() throws -> UTCInstant { try UTCInstant(secondsSince1970:Date().timeIntervalSince1970) }
    func monotonicElapsed() -> Duration { start.duration(to:.now) }
    func timezone() -> IANATimeZone { try! IANATimeZone(identifier:"UTC") }
}
private actor RecoveryReceiptVerifier: RunEffectVerifier {
    let client: PostgresClient, result: ActionResult
    var calls = 0
    init(client: PostgresClient,result: ActionResult) { self.client = client;self.result = result }
    func confirmedOutcome(for action: ActionRecord, deadline: ContinuousClock.Instant) async throws -> ActionResult? {
        calls += 1
        let rows = try await client.query("SELECT count(*)::bigint FROM recovery_receipts WHERE action_id=\(action.id)").collect()
        return try rows[0].decode(Int64.self) == 1 ? result : .failed(.notApplied)
    }
}
private actor LostRecoveryAcknowledgement: RunStore {
    let base: PostgresRunStore, loseWrite: Int
    var writes = 0
    init(_ base:PostgresRunStore,loseWrite:Int) { self.base = base;self.loseWrite = loseWrite }
    func create(_ snapshot: RunSnapshot, deadline: ContinuousClock.Instant) async throws { try await base.create(snapshot,deadline:deadline) }
    func load(actorID: UUID,runID: UUID,deadline: ContinuousClock.Instant) async throws -> RunSnapshot { try await base.load(actorID:actorID,runID:runID,deadline:deadline) }
    func compareAndSet(_ snapshot: RunSnapshot,expectedVersion: Int64,deadline: ContinuousClock.Instant) async throws {
        try await base.compareAndSet(snapshot,expectedVersion:expectedVersion,deadline:deadline)
        writes += 1
        if writes == loseWrite { throw RunStoreError.unavailable }
    }
}
// SAFETY: isolated UUID scopes, actor-owned counters and separate SQL clients.
final class RunRecoverySQLTests: XCTestCase, @unchecked Sendable {
    func testDurableRecoveryAcrossReservationEffectResultAndLostAcknowledgementBoundaries() async throws {
        let env = ProcessInfo.processInfo.environment
        let port = try XCTUnwrap(env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init)),password = try XCTUnwrap(env["SQUIDRA_TEST_DB_PASSWORD"])
        let config = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra")
        let client = config.makeClient(),restartedClient = config.makeClient()
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };group.addTask { await restartedClient.run() };defer { group.cancelAll() }
            _ = try await client.query("CREATE TABLE recovery_receipts(action_id uuid PRIMARY KEY)").collect()
            for stage in 0..<6 {
                let clock = RecoverySQLClock(),runs = PostgresRunStore(client:client),store = PostgresActionLedger(client:client)
                let old = try await RunController.create(actorID:UUID(),store:runs,clock:clock)
                _ = try await old.transition(to:.validating);_ = try await old.transition(to:.contextLoading);_ = try await old.transition(to:.planning)
                let initial = try await old.snapshot(),tool = try ToolID(namespace:"fixture",name:"echo",version:"1.0.0")
                let command = try ActionCommand(actorID:initial.actorID,runID:initial.id,tool:tool,idempotencyKey:"original-key",target:"entity:fixture",arguments:Data("{}".utf8),scope:["fixture:write"])
                _ = try await old.validatedProposal(semanticDigest:command.fingerprintHex,invocationKey:command.idempotencyKey)
                _ = try await old.transition(to:.executingTool);_ = try await old.reserveToolAttempt(timeoutMilliseconds:5000)
                let ledger = ActionLedger(store:store),record: ActionRecord
                if stage == 0 { record = try await store.reserve(command,deadline:.now.advanced(by:.seconds(4))).record }
                else {
                    guard case .dispatch(let permit) = try await ledger.prepare(command,deadline:.now.advanced(by:.seconds(4))) else { return XCTFail("No initial permit") }
                    record = permit.record
                }
                let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let definition = try ToolDefinition(id:tool,capability:"fixture.read",risk:.r0,idempotency:.readOnly,
                    inputSchema:Data(contentsOf:root.appendingPathComponent("Schemas/tools/fixture.echo.1.0.0.input.json")),
                    outputSchema:Data(contentsOf:root.appendingPathComponent("Schemas/tools/fixture.echo.1.0.0.output.json")))
                let output = try ToolCatalog(definitions:[definition]).validateOutput(Data(#"{"schemaVersion":"1","entityId":"00000000-0000-0000-0000-000000000001","message":"confirmed receipt"}"#.utf8),for:tool)
                let result = try ActionResult.succeeded(output,for:tool)
                if stage >= 2 { _ = try await client.query("INSERT INTO recovery_receipts(action_id) VALUES(\(record.id))").collect() }
                if stage == 3 { _ = try await ledger.reconcile(record,confirmed:result,deadline:.now.advanced(by:.seconds(4))) }
                // Original worker is no longer running; reopen both stores over
                // another client. No in-memory controller state is transferred.
                let restoredRuns = PostgresRunStore(client:restartedClient),restoredActions = PostgresActionLedger(client:restartedClient)
                let verifier = RecoveryReceiptVerifier(client:restartedClient,result:result)
                var checkpoint = try await restoredRuns.load(actorID:initial.actorID,runID:initial.id,deadline:.now.advanced(by:.seconds(4)))
                if stage >= 4 {
                    let faulty = LostRecoveryAcknowledgement(restoredRuns,loseWrite:stage == 4 ? 1 : 2)
                    do {
                        _ = try await RunRecovery(runs:faulty,actions:restoredActions,verifier:verifier,clock:clock).recover(actorID:initial.actorID,runID:initial.id,expectedVersion:checkpoint.version,actionID:record.id)
                        XCTFail("Lost acknowledgement granted continuation")
                    } catch { XCTAssertEqual(error as? RunStoreError,.unavailable) }
                    checkpoint = try await restoredRuns.load(actorID:initial.actorID,runID:initial.id,deadline:.now.advanced(by:.seconds(4)))
                }
                let recovery = RunRecovery(runs:restoredRuns,actions:restoredActions,verifier:verifier,clock:clock)
                guard case .ready(let controller) = try await recovery.recover(actorID:initial.actorID,runID:initial.id,expectedVersion:checkpoint.version,actionID:record.id) else { return XCTFail("Recovery failed") }
                let recovered = try await controller.snapshot()
                XCTAssertEqual(recovered.invocation?.key,"original-key");XCTAssertEqual(recovered.calls,1)
                XCTAssertEqual(recovered.budget,initial.budget)
                if stage == 0 {
                    XCTAssertEqual(recovered.invocation?.outcome,.retryableFailure)
                    _ = try await controller.transition(to:.cancelled,terminalCode:.cancelled)
                } else if stage == 1 {
                    XCTAssertEqual(recovered.invocation?.outcome,.failed)
                    _ = try await controller.transition(to:.failed,terminalCode:.failed)
                } else {
                    XCTAssertEqual(recovered.invocation?.outcome,.confirmed)
                    _ = try await controller.transition(to:.responding)
                    _ = try await controller.finishIteration(progress:.confirmedEffect)
                    _ = try await controller.transition(to:.completed,terminalCode:.completed)
                    guard case .replay(let replay) = try await ActionLedger(store:restoredActions).prepare(command,deadline:.now.advanced(by:.seconds(4))) else { return XCTFail("Recovered effect dispatched again") }
                    XCTAssertEqual(replay.result,result)
                }
                let final = try await runs.load(actorID:initial.actorID,runID:initial.id,deadline:.now.advanced(by:.seconds(4)))
                XCTAssertTrue(final.state.isTerminal);XCTAssertEqual(final.calls,1)
                let receipts = try await client.query("SELECT count(*)::bigint FROM recovery_receipts WHERE action_id=\(record.id)").collect()
                XCTAssertEqual(try receipts[0].decode(Int64.self),stage >= 2 ? 1 : 0)
                let verifications = await verifier.calls
                XCTAssertEqual(verifications,(stage == 0 || stage == 3) ? 0 : 1)
            }
        }
    }
}
