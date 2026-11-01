import Foundation
import PostgresNIO
import SquidraAgentRuntime
import SquidraDomain
import SquidraPostgres
import SquidraSecurity
import SquidraTools

struct FixtureClock: SquidraDomain.Clock {
    let start = ContinuousClock.now
    func now() throws -> UTCInstant { try UTCInstant(secondsSince1970:Date().timeIntervalSince1970) }
    func monotonicElapsed() -> Duration { start.duration(to:.now) }
    func timezone() -> IANATimeZone { try! IANATimeZone(identifier:"UTC") }
}
struct Manifest: Codable { let actor:UUID,run:UUID,action:UUID,stage:String }
enum FixtureFailure: Error { case invalid, repeated, missing }
struct ReceiptVerifier: RunEffectVerifier {
    let client:PostgresClient,result:ActionResult
    func confirmedOutcome(for action:ActionRecord,deadline:ContinuousClock.Instant) async throws -> ActionResult? {
        let rows = try await client.query("SELECT count(*)::bigint FROM crash_receipts WHERE action_id=\(action.id)").collect()
        return try rows[0].decode(Int64.self) == 1 ? result : nil
    }
}
@main struct RunCrashFixture {
    static func main() async {
        do { try await run() }
        catch {
            // Only closed, data-free error enums; never SQL/provider descriptions.
            if let error = error as? ApprovalError { print("CRASH_FIXTURE_FAILED:approval:\(error)") }
            else if let error = error as? RunError { print("CRASH_FIXTURE_FAILED:run:\(error)") }
            else { print("CRASH_FIXTURE_FAILED") }
            exit(1)
        }
    }
    static func run() async throws {
        let args = CommandLine.arguments,env = ProcessInfo.processInfo.environment
        guard args.count == 4,["seed","resume","verify"].contains(args[1]),(["reserved","pending","effect","result"].contains(args[2]) || approvalStages.contains(args[2])),
              env["SQUIDRA_RUN_CRASH_FIXTURE"] == "1",let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw FixtureFailure.invalid }
        let path = URL(fileURLWithPath:args[3]),clock = FixtureClock()
        let client = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
        let tool = try ToolID(namespace:"fixture",name:"echo",version:"1.0.0")
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let definition = try ToolDefinition(id:tool,capability:"fixture.read",risk:.r0,idempotency:.readOnly,
            inputSchema:Data(contentsOf:root.appendingPathComponent("Schemas/tools/fixture.echo.1.0.0.input.json")),
            outputSchema:Data(contentsOf:root.appendingPathComponent("Schemas/tools/fixture.echo.1.0.0.output.json")))
        let payload = Data(#"{"schemaVersion":"1","entityId":"00000000-0000-0000-0000-000000000001","message":"committed fixture receipt"}"#.utf8)
        let result = try ActionResult.succeeded(ToolCatalog(definitions:[definition]).validateOutput(payload,for:tool),for:tool)
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            if approvalStages.contains(args[2]) {
                try await approvalCrash(mode:args[1],stage:args[2],path:path,client:client,clock:clock,tool:tool)
                return
            }
            guard args[1] != "verify" else { throw FixtureFailure.invalid }
            let runs = PostgresRunStore(client:client),store = PostgresActionLedger(client:client),ledger = ActionLedger(store:store)
            if args[1] == "seed" {
                _ = try await client.query("CREATE TABLE IF NOT EXISTS crash_receipts(action_id uuid PRIMARY KEY)").collect()
                let controller = try await RunController.create(actorID:UUID(),store:runs,clock:clock)
                _ = try await controller.transition(to:.validating);_ = try await controller.transition(to:.contextLoading);_ = try await controller.transition(to:.planning)
                let initial = try await controller.snapshot()
                let command = try command(actor:initial.actorID,run:initial.id,tool:tool)
                _ = try await controller.validatedProposal(semanticDigest:command.fingerprintHex,invocationKey:command.idempotencyKey)
                _ = try await controller.transition(to:.executingTool);_ = try await controller.reserveToolAttempt(timeoutMilliseconds:5000)
                let record:ActionRecord
                if args[2] == "reserved" { record = try await store.reserve(command,deadline:.now.advanced(by:.seconds(4))).record }
                else {
                    guard case .dispatch(let permit) = try await ledger.prepare(command,deadline:.now.advanced(by:.seconds(4))) else { throw FixtureFailure.invalid }
                    record = permit.record
                }
                if ["effect","result"].contains(args[2]) { _ = try await client.query("INSERT INTO crash_receipts(action_id) VALUES(\(record.id))").collect() }
                if args[2] == "result" { _ = try await ledger.reconcile(record,confirmed:result,deadline:.now.advanced(by:.seconds(4))) }
                try JSONEncoder().encode(Manifest(actor:initial.actorID,run:initial.id,action:record.id,stage:args[2])).write(to:path,options:.atomic)
                // Parent waits for the committed marker, then SIGKILLs this
                // exact owned process. No graceful-shutdown cleanup runs.
                try await Task.sleep(for:.seconds(120))
                throw FixtureFailure.invalid
            } else {
                let manifest = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:path))
                guard manifest.stage == args[2] else { throw FixtureFailure.invalid }
                let checkpoint = try await runs.load(actorID:manifest.actor,runID:manifest.run,deadline:.now.advanced(by:.seconds(4)))
                let command = try command(actor:manifest.actor,run:manifest.run,tool:tool)
                let recovery = RunRecovery(runs:runs,actions:store,verifier:ReceiptVerifier(client:client,result:result),clock:clock)
                let recovered = try await recovery.recover(actorID:manifest.actor,runID:manifest.run,expectedVersion:checkpoint.version,actionID:manifest.action)
                if args[2] == "pending" {
                    guard case .terminal(let terminal) = recovered,terminal.terminalCode == .recoveryRequired else { throw FixtureFailure.invalid }
                } else {
                    guard case .ready(let controller) = recovered else { throw FixtureFailure.missing }
                    if args[2] == "reserved" {
                        try await Task.sleep(for:.milliseconds(600))
                        guard let attempt = try await controller.reserveToolAttempt(timeoutMilliseconds:5000),attempt.idempotencyKey == command.idempotencyKey else { throw FixtureFailure.invalid }
                        guard case .dispatch(let permit) = try await ledger.prepare(command,deadline:attempt.deadline) else { throw FixtureFailure.missing }
                        _ = try await client.query("INSERT INTO crash_receipts(action_id) VALUES(\(permit.record.id))").collect()
                        _ = try await ledger.complete(permit,result:result,deadline:attempt.deadline)
                        _ = try await controller.finishToolAttempt(.confirmed)
                    }
                    _ = try await controller.transition(to:.responding)
                    _ = try await controller.finishIteration(progress:.confirmedEffect)
                    _ = try await controller.transition(to:.completed,terminalCode:.completed)
                    guard case .replay(let persisted) = try await ledger.prepare(command,deadline:.now.advanced(by:.seconds(4))),persisted.result?.payload == result.payload else { throw FixtureFailure.repeated }
                }
                let final = try await runs.load(actorID:manifest.actor,runID:manifest.run,deadline:.now.advanced(by:.seconds(4)))
                guard final.state.isTerminal,final.calls == (args[2] == "reserved" ? 2 : 1) else { throw FixtureFailure.invalid }
                let rows = try await client.query("SELECT count(*)::bigint FROM crash_receipts WHERE action_id=\(manifest.action)").collect()
                guard try rows[0].decode(Int64.self) == (args[2] == "pending" ? 0 : 1) else { throw FixtureFailure.repeated }
                print("CRASH_RECOVERY_VERIFIED")
            }
        }
    }
    static func command(actor:UUID,run:UUID,tool:ToolID) throws -> ActionCommand {
        try ActionCommand(actorID:actor,runID:run,tool:tool,idempotencyKey:"original-key",target:"fixture:receipt",arguments:Data("{}".utf8),scope:["fixture:write"])
    }
}
