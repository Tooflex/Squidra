import Foundation
import Logging
import PostgresNIO
import SquidraPostgres
import SquidraSecurity
import XCTest
@testable import SquidraTools

private actor MemoryLedger: ActionLedgerStore {
    private struct Key: Hashable { let actor: UUID; let tool: String; let key: String }
    private var records: [UUID:ActionRecord] = [:]
    private var keys: [Key:UUID] = [:]
    func reserve(_ command: ActionCommand, deadline: ContinuousClock.Instant) throws -> ActionReservation {
        let key = Key(actor: command.actorID, tool: command.tool.qualifiedName, key: command.idempotencyKey)
        if let id = keys[key], let record = records[id] {
            guard record.command.fingerprint == command.fingerprint else { throw ActionLedgerError.conflict }
            return .init(record: record, created: false)
        }
        let record = try ActionRecord(id: UUID(), command: command, status: .reserved, version: 1, result: nil, providerReference: nil)
        keys[key] = record.id; records[record.id] = record
        return .init(record: record, created: true)
    }
    func load(actorID: UUID, id: UUID, deadline: ContinuousClock.Instant) throws -> ActionRecord {
        guard let value = records[id], value.command.actorID == actorID else { throw ActionLedgerError.notFound }
        return value
    }
    func update(_ record: ActionRecord, to status: ActionStatus, result: ActionResult?, providerReference: String?, deadline: ContinuousClock.Instant) throws -> ActionRecord {
        let current = try load(actorID: record.command.actorID, id: record.id, deadline: deadline)
        guard current.version == record.version else { throw ActionLedgerError.versionConflict }
        let allowed = (current.status == .reserved && status == .pending)
            || (current.status == .pending && (status == .unknown || status.isFinal)) || (current.status == .unknown && status.isFinal)
        guard allowed else { throw ActionLedgerError.reconciliationRequired }
        let next = try ActionRecord(id: record.id, command: current.command, status: status, version: record.version+1, result: result, providerReference: providerReference)
        records[record.id] = next; return next
    }
}

// SAFETY: no mutable instance state. Remove when the runner supports Swift Testing.
final class ActionFingerprintTests: XCTestCase, @unchecked Sendable {
    private static let actor = UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
    private static func command(_ json: String = #"{"a":1,"b":2}"#, actor: UUID = ActionFingerprintTests.actor,
                                run: UUID = UUID(), key: String = "same-key", version: String = "1.0.0",
                                target: String = "entity:1", scope: [String] = ["world:read"]) throws -> ActionCommand {
        try ActionCommand(actorID: actor, runID: run, tool: ToolID(namespace:"fixture",name:"echo",version:version),
            idempotencyKey:key,target:target,arguments:Data(json.utf8),scope:scope)
    }
    func testGoldenSHAAndEquivalentKeysNumbersAndScopes() throws {
        let original = try Self.command()
        // Independent Python hashlib vector from the frozen profile's literal bytes.
        XCTAssertEqual(original.fingerprintHex,"ff66feb3936183f6734a5145ee43981f75a3f5235e597c65e803d4363ae7dbfc")
        let equivalent = try Self.command(#"{"b":2.00,"a":1e0}"#,key:"different-key",scope:["world:read","world:read"])
        XCTAssertEqual(original.fingerprint,equivalent.fingerprint)
        XCTAssertNotEqual(original.runID,equivalent.runID)
        XCTAssertEqual(equivalent.scope,["world:read"])
    }
    func testDecimalNormalizationWithoutDoublePrecisionLoss() throws {
        let zero = try Self.command(#"{"n":0}"#).fingerprint
        for value in ["-0","0.0","0e5"] { XCTAssertEqual(try Self.command("{\"n\":\(value)}").fingerprint,zero) }
        XCTAssertEqual(try Self.command(#"{"n":0.10}"#).fingerprint,try Self.command(#"{"n":1e-1}"#).fingerprint)
        XCTAssertNotEqual(try Self.command(#"{"n":9007199254740992}"#).fingerprint,try Self.command(#"{"n":9007199254740993}"#).fingerprint)
        XCTAssertNotEqual(try Self.command(#"{"n":true}"#).fingerprint,try Self.command(#"{"n":1}"#).fingerprint)
    }
    func testEverySemanticFieldChangesTheFingerprint() throws {
        let original = try Self.command()
        for changed in try [Self.command(actor:UUID()),Self.command(version:"1.0.1"),Self.command(target:"entity:2"),Self.command(scope:["world:write"]),Self.command(#"{"a":2,"b":2}"#)] {
            XCTAssertNotEqual(changed.fingerprint,original.fingerprint)
        }
    }
    func testStorageExpansionNULAndInvalidScopeAreRejected() throws {
        for json in [#"{"n":1e308}"#,#"{"n":1e-200}"#,#"{"n":0e999999}"#,#"{"n":"\u0000"}"#,#"{"\u0000":1}"#,#"{"n":1,"n":2}"#] {
            XCTAssertThrowsError(try Self.command(json)) { XCTAssertEqual($0 as? ActionLedgerError,.invalidCommand) }
        }
        XCTAssertThrowsError(try Self.command(scope:["unsafe\nscope"]))
        XCTAssertThrowsError(try Self.command(scope:["nonascii:é"]))
    }
    func testReplayAndConflictingReuse() async throws {
        let store = MemoryLedger(), ledger = ActionLedger(store:store), command = try Self.command()
        guard case .dispatch(let permit) = try await ledger.prepare(command,deadline:.now.advanced(by:.seconds(2))) else { return XCTFail("No dispatch claim") }
        let outcome = ActionResult.failed(.providerFailure)
        let final = try await ledger.complete(permit,result:outcome,deadline:.now.advanced(by:.seconds(2)))
        let duplicateFinal = try await ledger.complete(permit,result:outcome,deadline:.now.advanced(by:.seconds(2)))
        XCTAssertEqual(final,duplicateFinal)
        guard case .replay(let replay) = try await ledger.prepare(Self.command(#"{"b":2e0,"a":1.0}"#),deadline:.now.advanced(by:.seconds(2))) else { return XCTFail("No replay") }
        XCTAssertEqual(replay.result,outcome)
        do { _ = try await ledger.prepare(Self.command(target:"entity:2"),deadline:.now.advanced(by:.seconds(2))); XCTFail("Key reused for other target") }
        catch { XCTAssertEqual(error as? ActionLedgerError,.conflict) }
    }
    func testUnknownRequiresExplicitConfirmedReconciliationAndNoRetry() async throws {
        let store = MemoryLedger(), ledger = ActionLedger(store:store), command = try Self.command()
        guard case .dispatch(let permit) = try await ledger.prepare(command,deadline:.now.advanced(by:.seconds(2))) else { return XCTFail("No dispatch") }
        let unknown = try await ledger.markUnknown(permit,deadline:.now.advanced(by:.seconds(2)))
        guard case .reconciliationRequired = try await ledger.prepare(command,deadline:.now.advanced(by:.seconds(2))) else { return XCTFail("Unknown became executable") }
        do { _ = try await store.update(unknown,to:.pending,result:nil,providerReference:nil,deadline:.now.advanced(by:.seconds(2))); XCTFail("Blind retry authorized") }
        catch { XCTAssertEqual(error as? ActionLedgerError,.reconciliationRequired) }
        _ = try await ledger.reconcile(unknown,confirmed:.failed(.notApplied),deadline:.now.advanced(by:.seconds(2)))
        guard case .replay = try await ledger.prepare(command,deadline:.now.advanced(by:.seconds(2))) else { return XCTFail("Known outcome not replayed") }
    }
    func testUnknownCannotBeFinalizedByAnOldDispatchPermit() async throws {
        let ledger = ActionLedger(store:MemoryLedger()), command = try Self.command()
        guard case .dispatch(let permit) = try await ledger.prepare(command,deadline:.now.advanced(by:.seconds(2))) else { return XCTFail("No dispatch") }
        _ = try await ledger.markUnknown(permit,deadline:.now.advanced(by:.seconds(2)))
        do { _ = try await ledger.complete(permit,result:.failed(.providerFailure),deadline:.now.advanced(by:.seconds(2))); XCTFail("Stale permit overwrote unknown") }
        catch { XCTAssertEqual(error as? ActionLedgerError,.reconciliationRequired) }
    }
    func testCrashBeforeClaimCanClaimOnceButAfterClaimNeverDispatchesAgain() async throws {
        let store = MemoryLedger(), command = try Self.command()
        // Crash after durable reservation, before a claim or effect.
        _ = try await store.reserve(command,deadline:.now.advanced(by:.seconds(2)))
        guard case .dispatch(let recovered) = try await ActionLedger(store:store).prepare(command,deadline:.now.advanced(by:.seconds(2))) else {
            return XCTFail("Unclaimed reservation could not recover")
        }
        XCTAssertEqual(recovered.record.command.idempotencyKey,command.idempotencyKey)
        guard case .inProgress = try await ActionLedger(store:store).prepare(command,deadline:.now.advanced(by:.seconds(2))) else {
            return XCTFail("Recovered claim dispatched twice")
        }
        let freshStore = MemoryLedger(), freshCommand = try Self.command(key:"before-effect")
        guard case .dispatch = try await ActionLedger(store:freshStore).prepare(freshCommand,deadline:.now.advanced(by:.seconds(2))) else {
            return XCTFail("Initial claim missing")
        }
        // Restart after a claim; it is impossible to know whether an effect ran.
        guard case .inProgress = try await ActionLedger(store:freshStore).prepare(freshCommand,deadline:.now.advanced(by:.seconds(2))) else {
            return XCTFail("A stranded claim dispatched again")
        }
    }
    func testExistingUnclaimedReservationHasOneWinnerAfterRestart() async throws {
        let store = MemoryLedger(),command = try Self.command(key:"reserved-before-crash")
        let reserved = try await store.reserve(command,deadline:.now.advanced(by:.seconds(2)))
        XCTAssertEqual(reserved.record.status,.reserved)
        async let a = ActionLedger(store:store).prepare(command,deadline:.now.advanced(by:.seconds(2)))
        async let b = ActionLedger(store:store).prepare(command,deadline:.now.advanced(by:.seconds(2)))
        let outcomes = try await [a,b]
        let permits = outcomes.compactMap { if case .dispatch(let permit) = $0 { return permit };return nil as ActionDispatchPermit? }
        XCTAssertEqual(permits.count,1);XCTAssertEqual(permits.first?.record.id,reserved.record.id)
        guard case .inProgress = try await ActionLedger(store:store).prepare(command,deadline:.now.advanced(by:.seconds(2))) else { return XCTFail("Pending claim dispatched again") }
    }
    func testInternalResultVersionIsActuallyValidatedOnDecode() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(ActionResult.failed(.notApplied))) as? [String:Any])
        json["schemaVersion"] = 99
        let decoded = try JSONDecoder().decode(ActionResult.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertThrowsError(try decoded.validate())
    }
}

// SAFETY: no mutable instance state; owns an isolated real database fixture.
final class ActionLedgerSQLTests: XCTestCase, @unchecked Sendable {
    private static let logger = Logger(label:"squidra.ledger-test",factory:{ _ in SwiftLogNoOpLogHandler() })
    private static func outcome(tool: ToolID) throws -> ActionResult {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let definition = try ToolDefinition(id:tool,capability:"fixture.read",risk:.r0,idempotency:.readOnly,
            inputSchema:Data(contentsOf:root.appendingPathComponent("Schemas/tools/fixture.echo.1.0.0.input.json")),
            outputSchema:Data(contentsOf:root.appendingPathComponent("Schemas/tools/fixture.echo.1.0.0.output.json")))
        let result = try ToolCatalog(definitions:[definition]).validateOutput(Data(#"{"schemaVersion":"1","entityId":"00000000-0000-0000-0000-000000000001","message":"fixture committed"}"#.utf8),for:tool)
        return try .succeeded(result,for:tool)
    }
    private actor InterruptedEffect: ToolExecutor {
        let client: PostgresClient, receipt: UUID
        var committed = false, calls = 0
        init(client: PostgresClient, receipt: UUID) { self.client = client;self.receipt = receipt }
        func execute(_ call: ToolCall) async throws -> Data {
            calls += 1
            _ = try await client.query("INSERT INTO cancellation_effects(receipt) VALUES(\(receipt))").collect()
            committed = true
            try await Task.sleep(for:.seconds(30))
            throw CancellationError()
        }
    }
    func testCancelledAndExpiredGatewayEffectsSurviveRestartAsUnknownUntilConfirmed() async throws {
        let env = ProcessInfo.processInfo.environment
        let port = try XCTUnwrap(env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init)),password = try XCTUnwrap(env["SQUIDRA_TEST_DB_PASSWORD"])
        let config = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra")
        let client = config.makeClient(),readback = config.makeClient()
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tool = try ToolID(namespace:"fixture",name:"echo",version:"1.0.0")
        let definition = try ToolDefinition(id:tool,capability:"fixture.read",risk:.r1,idempotency:.durableLedger,timeoutMilliseconds:2000,
            inputSchema:Data(contentsOf:root.appendingPathComponent("Schemas/tools/fixture.echo.1.0.0.input.json")),
            outputSchema:Data(contentsOf:root.appendingPathComponent("Schemas/tools/fixture.echo.1.0.0.output.json")))
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };group.addTask { await readback.run() };defer { group.cancelAll() }
            _ = try await client.query("CREATE TABLE cancellation_effects(receipt uuid PRIMARY KEY)").collect()
            for cancel in [true,false] {
                let actor = UUID(),run = UUID(),receipt = UUID(),target = "entity:00000000-0000-0000-0000-000000000001"
                _ = try await client.query("INSERT INTO agent_runs(id,actor_id,trace_id) VALUES(\(run),\(actor),\(UUID()))").collect()
                let executor = InterruptedEffect(client:client,receipt:receipt)
                let permission = HostActionPermission(actorID:actor,tool:tool,capability:"fixture.read",targets:[target],scope:["fixture:read"],expiresAt:.now.advanced(by:.seconds(20)))
                let registration = GatewayToolRegistration(definition:definition,surface:.bounded,executor:executor,resolveTarget:{ _ in target })
                let gateway = try ActionGateway(tools:[registration],policy:HostActionPolicy(permissions:[permission]),ledger:ActionLedger(store:PostgresActionLedger(client:client)))
                let input = Data(#"{"schemaVersion":"1","entityId":"00000000-0000-0000-0000-000000000001","at":"2026-10-31T12:00:00Z","message":"fixture","limit":1}"#.utf8)
                let action = GatewayAction(actorID:actor,runID:run,tool:tool,target:target,arguments:input,scope:["fixture:read"],idempotencyKey:"cancel-effect",deadline:.now.advanced(by:cancel ? .seconds(5) : .seconds(1)))
                let worker = Task { try await gateway.invoke(action) }
                let end = ContinuousClock.now.advanced(by:.seconds(3))
                while !(await executor.committed) {
                    guard ContinuousClock.now < end else { worker.cancel();_ = try? await worker.value;return XCTFail("Effect never committed") }
                    try await Task.sleep(for:.milliseconds(2))
                }
                if cancel { worker.cancel() }
                do { _ = try await worker.value;XCTFail("Interrupted mutation reported success") } catch {}
                let restarted = ActionLedger(store:PostgresActionLedger(client:readback))
                let command = try ActionCommand(actorID:actor,runID:run,tool:tool,idempotencyKey:"cancel-effect",target:target,arguments:input,scope:["fixture:read"])
                guard case .reconciliationRequired(let unknown) = try await restarted.prepare(command,deadline:.now.advanced(by:.seconds(4))) else { return XCTFail("Durable unknown lost on restart") }
                XCTAssertEqual(unknown.status,.unknown);XCTAssertNil(unknown.result)
                let rows = try await readback.query("SELECT count(*)::bigint FROM cancellation_effects WHERE receipt=\(receipt)").collect()
                XCTAssertEqual(try rows[0].decode(Int64.self),1)
                // Independent provider receipt confirms the effect actually happened.
                let outcome = try Self.outcome(tool:tool)
                _ = try await restarted.reconcile(unknown,confirmed:outcome,providerReference:receipt.uuidString,deadline:.now.advanced(by:.seconds(4)))
                guard case .replay(let final) = try await restarted.prepare(command,deadline:.now.advanced(by:.seconds(4))) else { return XCTFail("Confirmed effect not replayed") }
                XCTAssertEqual(final.status,.succeeded);XCTAssertEqual(final.providerReference,receipt.uuidString)
                let calls = await executor.calls;XCTAssertEqual(calls,1)
            }
        }
    }
    func testRealConcurrentSingleEffectReplayConflictsUnknownAndAtomicOutbox() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["SQUIDRA_TEST_DB_PORT"],let port = Int(text),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            XCTFail("Run through the isolated SQD-007 database helper");return
        }
        let config = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra")
        let client = config.makeClient(),store = PostgresActionLedger(client:client),ledger = ActionLedger(store:store)
        let actor = UUID(),otherActor = UUID(),run = UUID(),retryRun = UUID(),otherRun = UUID(),tool = try ToolID(namespace:"fixture",name:"echo",version:"1.0.0")
        func command(_ args: String = #"{"n":1}"#,key: String = "shared",actorID: UUID = actor,runID: UUID = run,
                     toolID: ToolID = tool,target: String = "entity:1",scope:[String] = ["fixture:read"]) throws -> ActionCommand {
            try ActionCommand(actorID:actorID,runID:runID,tool:toolID,idempotencyKey:key,target:target,arguments:Data(args.utf8),scope:scope)
        }
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            _ = try await client.query("INSERT INTO agent_runs(id,actor_id,trace_id) VALUES(\(run),\(actor),\(UUID())),(\(retryRun),\(actor),\(UUID())),(\(otherRun),\(otherActor),\(UUID()))").collect()
            _ = try await client.query("CREATE TABLE fixture_effects(ledger_id uuid NOT NULL)").collect()
            for (index, json) in [#"{"n":9007199254740993,"a":1e-20,"s":"e\u0301"}"#,
                                  #"{"n":1e100,"a":1e-100,"zero":-0.00}"#].enumerated() {
                let value = try command(json,key:"numeric-\(index)")
                let reservation = try await store.reserve(value,deadline:.now.advanced(by:.seconds(2)))
                let reloaded = try await store.load(actorID:actor,id:reservation.record.id,deadline:.now.advanced(by:.seconds(2)))
                XCTAssertEqual(value.fingerprint,reloaded.command.fingerprint)
            }
            let first = try command(),second = try command(#"{"n":1.00}"#,runID:retryRun)
            let preparations = try await client.withConnection(isolation:nil) { blocker in
                var transactionOpen = true
                defer { if transactionOpen { blocker.close().whenFailure { _ in } } }
                _ = try await blocker.query("BEGIN",logger:Self.logger).collect()
                _ = try await blocker.query("SELECT id FROM agent_runs WHERE id=\(run) OR id=\(retryRun) FOR UPDATE",logger:Self.logger).collect()
                async let a = ledger.prepare(first,deadline:.now.advanced(by:.seconds(2)))
                async let b = ledger.prepare(second,deadline:.now.advanced(by:.seconds(2)))
                let limit = ContinuousClock.now.advanced(by:.seconds(1));var blocked:Int64 = 0
                repeat {
                    let rows = try await client.query("SELECT count(*)::bigint FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%reserve_action%'").collect()
                    blocked = try rows[0].decode(Int64.self)
                    if blocked >= 2 { break }
                    try await Task.sleep(for:.milliseconds(10))
                } while ContinuousClock.now < limit
                XCTAssertGreaterThanOrEqual(blocked,2)
                _ = try await blocker.query("ROLLBACK",logger:Self.logger).collect();transactionOpen = false
                return try await [a,b]
            }
            let permits = preparations.compactMap { if case .dispatch(let permit) = $0 { return permit };return nil as ActionDispatchPermit? }
            XCTAssertEqual(permits.count,1)
            let permit = try XCTUnwrap(permits.first)
            _ = try await client.query("INSERT INTO fixture_effects VALUES(\(permit.record.id))").collect()
            let outcome = try Self.outcome(tool:tool)
            let final = try await ledger.complete(permit,result:outcome,providerReference:"fixture-receipt",deadline:.now.advanced(by:.seconds(2)))
            _ = try await ledger.complete(permit,result:outcome,providerReference:"fixture-receipt",deadline:.now.advanced(by:.seconds(2)))
            guard case .replay(let replay) = try await ActionLedger(store:PostgresActionLedger(client:client)).prepare(second,deadline:.now.advanced(by:.seconds(2))) else { return XCTFail("No persisted replay") }
            XCTAssertEqual(replay.id,final.id);XCTAssertEqual(replay.result?.payload,outcome.payload)
            let counts = try await client.query("SELECT (SELECT count(*) FROM fixture_effects)::bigint,(SELECT count(*) FROM outbox WHERE ledger_id=\(final.id))::bigint").collect()
            let (effects,notices) = try counts[0].decode((Int64,Int64).self)
            XCTAssertEqual(effects,1);XCTAssertEqual(notices,1)
            for conflicting in try [command(#"{"n":2}"#),command(target:"entity:2"),command(scope:["fixture:write"]),command(toolID:ToolID(namespace:"fixture",name:"echo",version:"1.0.1"))] {
                do { _ = try await ledger.prepare(conflicting,deadline:.now.advanced(by:.seconds(2)));XCTFail("Conflicting key reuse accepted") }
                catch { XCTAssertEqual(error as? ActionLedgerError,.conflict) }
            }
            guard case .dispatch = try await ledger.prepare(command(actorID:otherActor,runID:otherRun),deadline:.now.advanced(by:.seconds(2))) else { return XCTFail("Actor keys collided") }
            guard case .dispatch = try await ledger.prepare(command(toolID:ToolID(namespace:"fixture",name:"other",version:"1.0.0")),deadline:.now.advanced(by:.seconds(2))) else { return XCTFail("Tool keys collided") }
            do { _ = try await store.load(actorID:otherActor,id:final.id,deadline:.now.advanced(by:.seconds(2)));XCTFail("Actor boundary bypassed") }
            catch { XCTAssertEqual(error as? ActionLedgerError,.notFound) }
            guard case .dispatch(let uncertain) = try await ledger.prepare(command(key:"uncertain"),deadline:.now.advanced(by:.seconds(2))) else { return XCTFail("No uncertain claim") }
            _ = try await client.query("INSERT INTO fixture_effects VALUES(\(uncertain.record.id))").collect()
            let unknown = try await ledger.markUnknown(uncertain,providerReference:"fixture-uncertain",deadline:.now.advanced(by:.seconds(2)))
            guard case .reconciliationRequired = try await ledger.prepare(command(key:"uncertain"),deadline:.now.advanced(by:.seconds(2))) else { return XCTFail("Unknown replayed blindly") }
            do { _ = try await store.update(unknown,to:.pending,result:nil,providerReference:nil,deadline:.now.advanced(by:.seconds(2)));XCTFail("Unknown reset") }
            catch { XCTAssertEqual(error as? ActionLedgerError,.reconciliationRequired) }
            _ = try await ledger.reconcile(unknown,confirmed:outcome,providerReference:"fixture-confirmed",deadline:.now.advanced(by:.seconds(2)))
            let uncertainCounts = try await client.query("SELECT count(*)::bigint FROM fixture_effects WHERE ledger_id=\(unknown.id)").collect()
            XCTAssertEqual(try uncertainCounts[0].decode(Int64.self),1)
            guard case .dispatch(let atomic) = try await ledger.prepare(command(key:"atomic"),deadline:.now.advanced(by:.seconds(2))) else { return XCTFail("No atomic claim") }
            let dedupe = "action-result:"+atomic.record.id.uuidString.lowercased()
            _ = try await client.query("INSERT INTO outbox(actor_id,run_id,ledger_id,deduplication_key,payload) VALUES(\(actor),\(run),\(atomic.record.id),\(dedupe),'{}')").collect()
            do { _ = try await ledger.complete(atomic,result:outcome,deadline:.now.advanced(by:.seconds(2)));XCTFail("Outbox collision ignored") }
            catch { XCTAssertEqual(error as? ActionLedgerError,.conflict) }
            let rolledBack = try await store.load(actorID:actor,id:atomic.record.id,deadline:.now.advanced(by:.seconds(2)))
            XCTAssertEqual(rolledBack.status,.pending);XCTAssertNil(rolledBack.result)
            _ = try await client.query("DELETE FROM outbox WHERE actor_id=\(actor) AND deduplication_key=\(dedupe)").collect()
            _ = try await ledger.complete(atomic,result:outcome,deadline:.now.advanced(by:.seconds(2)))
        }
    }
}
