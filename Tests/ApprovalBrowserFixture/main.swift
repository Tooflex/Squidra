import Foundation
import PostgresNIO
import SquidraDomain
import SquidraPostgres
import SquidraSecurity
import SquidraTemporal
import SquidraTools

private enum Failure: Error { case invalid }
private struct Item: Codable { let id: UUID, ledger: UUID; let decision: String, digest: String, fingerprint: String; let requested: Int64 }
private struct Manifest: Codable { let actor: UUID, run: UUID; let items: [Item] }
private let arguments = Data(#"{"exactInteger":9007199254740993,"note":"<script>window.compromised=true</script>"}"#.utf8)
private func run() async throws {
    let env = ProcessInfo.processInfo.environment, args = Array(CommandLine.arguments.dropFirst())
    guard env["SQUIDRA_BROWSER_FIXTURE"] == "1", args.count == 2, ["seed","verify"].contains(args[0]),
          let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init), let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw Failure.invalid }
    let path = URL(fileURLWithPath:args[1])
    let client = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
    let ledger = PostgresActionLedger(client:client)
    let coordinator = ApprovalCoordinator(store:PostgresApprovalStore(client:client),clock:SystemClock(timeZone:try IANATimeZone(identifier:"Etc/UTC")))
    try await withThrowingTaskGroup(of:Void.self) { group in
        group.addTask { await client.run() }; defer { group.cancelAll() }
        if args[0] == "seed" {
            let actor = UUID(), run = UUID(); var items: [Item] = []
            _ = try await client.query("INSERT INTO agent_runs(id,actor_id,trace_id) VALUES(\(run),\(actor),\(UUID()))").collect()
            for decision in ["approved","denied","withdrawn","expired"] {
                let command = try ActionCommand(actorID:actor,runID:run,tool:ToolID(namespace:"fixture",name:"never_execute",version:"1.0.0"),idempotencyKey:decision,target:"fixture:exact-target",arguments:arguments,scope:["fixture:write"])
                let reserved = try await ledger.reserve(command,deadline:.now.advanced(by:.seconds(4)))
                let binding = try ApprovalBinding(actorID:actor,runID:run,ledgerID:reserved.record.id,commandHash:command.fingerprint)
                let record = try await coordinator.request(binding,ttlMilliseconds:decision == "expired" ? 1000 : 600000,deadline:.now.advanced(by:.seconds(4)))
                items.append(Item(id:record.id,ledger:reserved.record.id,decision:decision,digest:record.digest.map { String(format:"%02x",$0) }.joined(),fingerprint:command.fingerprintHex,requested:record.requestedAtMilliseconds))
            }
            try JSONEncoder().encode(Manifest(actor:actor,run:run,items:items)).write(to:path,options:.atomic)
            // The server owns expiry; no SQL timestamp is rewritten.
            try await Task.sleep(for:.milliseconds(1100))
        } else {
            let m = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:path))
            for item in m.items {
                let record = try await coordinator.load(actorID:m.actor,id:item.id,deadline:.now.advanced(by:.seconds(4)))
                let expected = try ActionCommand(actorID:m.actor,runID:m.run,tool:ToolID(namespace:"fixture",name:"never_execute",version:"1.0.0"),idempotencyKey:item.decision,target:"fixture:exact-target",arguments:arguments,scope:["fixture:write"])
                let action = try await ledger.load(actorID:m.actor,id:item.ledger,deadline:.now.advanced(by:.seconds(4)))
                let checks: [(String,Bool)] = [
                    ("decision",record.decision.rawValue == item.decision), ("version",record.version == 2),
                    ("run",record.binding.runID == m.run), ("ledger",record.binding.ledgerID == item.ledger),
                    ("digest",record.digest.map({ String(format:"%02x",$0) }).joined() == item.digest),
                    ("actor",record.approverID == (item.decision == "expired" ? nil : m.actor)),
                    ("reserved",action.status == .reserved), ("ledger-version",action.version == 1),
                    ("no-result",action.result == nil), ("no-receipt",action.providerReference == nil),
                    ("fingerprint",action.command.fingerprintHex == item.fingerprint),
                    ("expected-command",action.command.fingerprint == expected.fingerprint)]
                for (name,passed) in checks where !passed {
                    print("APPROVAL_FIXTURE_CHECK_FAILED:" + name); throw Failure.invalid
                }
                if item.decision == "expired" { guard record.decidedAtMilliseconds! >= record.expiresAtMilliseconds else { throw Failure.invalid } }
            }
            let rows = try await client.query("SELECT row_to_json(a)::text FROM approvals a WHERE actor_id=\(m.actor) ORDER BY id").collect()
            let actions = try await client.query("SELECT row_to_json(a)::text FROM action_ledger a WHERE actor_id=\(m.actor) ORDER BY id").collect()
            let bytes = try JSONEncoder().encode((rows+actions).map { try $0.decode(String.self) })
            let saved = path.appendingPathExtension("verified.json")
            if FileManager.default.fileExists(atPath:saved.path) { guard try Data(contentsOf:saved) == bytes else { throw Failure.invalid } }
            else { try bytes.write(to:saved,options:.atomic) }
        }
    }
}
do { try await run(); print("APPROVAL_BROWSER_FIXTURE_OK") }
catch { FileHandle.standardError.write(Data("Approval browser fixture failed.\n".utf8)); exit(1) }
