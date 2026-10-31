import Foundation
import Logging
import PostgresNIO
import SquidraDomain
import SquidraPostgres
import SquidraSecurity
import SquidraTemporal
import SquidraTools
import XCTest

// SAFETY: no mutable suite state; uses an isolated real PostgreSQL database.
final class ApprovalSQLTests: XCTestCase, @unchecked Sendable {
    private static let logger = Logger(label:"squidra.approval-test",factory:{ _ in SwiftLogNoOpLogHandler() })
    private static func outcome(_ service: ApprovalCoordinator, record: ApprovalRecord, response: ApprovalResponse) async -> Result<ApprovalRecord,ApprovalError> {
        do { return .success(try await service.resolve(actorID:record.binding.actorID,id:record.id,response:response,
            principalID:record.binding.actorID,expectedDigest:record.digest,deadline:.now.advanced(by:.seconds(4)))) }
        catch { return .failure(error as? ApprovalError ?? .unavailable) }
    }
    func testRealDurableApprovalReplayConcurrentDecisionAndExpiry() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let portText = env["SQUIDRA_TEST_DB_PORT"],let port = Int(portText),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            XCTFail("Run through the isolated approval persistence helper");return
        }
        let config = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra")
        let client = config.makeClient(),store = PostgresApprovalStore(client:client),ledger = PostgresActionLedger(client:client)
        let clock = SystemClock(timeZone:try IANATimeZone(identifier:"Etc/UTC")),service = ApprovalCoordinator(store:store,clock:clock)
        let actor = UUID(),run = UUID(),tool = try ToolID(namespace:"fixture",name:"approve",version:"1.0.0")
        @Sendable func binding(_ key: String) async throws -> ApprovalBinding {
            let command = try ActionCommand(actorID:actor,runID:run,tool:tool,idempotencyKey:key,target:"entity:1",arguments:Data(#"{"n":1}"#.utf8),scope:["fixture:write"])
            let reserved = try await ledger.reserve(command,deadline:.now.advanced(by:.seconds(4)))
            return try ApprovalBinding(actorID:actor,runID:run,ledgerID:reserved.record.id,commandHash:command.fingerprint)
        }
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            _ = try await client.query("INSERT INTO agent_runs(id,actor_id,trace_id) VALUES(\(run),\(actor),\(UUID()))").collect()
            let firstBinding = try await binding("first")
            let pending = try await service.request(firstBinding,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(pending.expiresAtMilliseconds-pending.requestedAtMilliseconds,600_000)
            let repeated = try await service.request(firstBinding,ttlMilliseconds:5_000,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(pending,repeated)
            let restarted = ApprovalCoordinator(store:PostgresApprovalStore(client:client),clock:clock)
            let reloaded = try await restarted.load(actorID:actor,id:pending.id,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(reloaded,pending)
            do { _ = try await restarted.verify(actorID:actor,id:pending.id,binding:firstBinding,deadline:.now.advanced(by:.seconds(4)));XCTFail("Pending authorized") }
            catch { XCTAssertEqual(error as? ApprovalError,.notApproved) }
            let approved = try await service.resolve(actorID:actor,id:pending.id,response:.approve,principalID:actor,expectedDigest:pending.digest,deadline:.now.advanced(by:.seconds(4)))
            let replay = try await restarted.resolve(actorID:actor,id:pending.id,response:.approve,principalID:actor,expectedDigest:pending.digest,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(approved,replay);XCTAssertEqual(replay.version,2)
            let proof = try await restarted.verify(actorID:actor,id:pending.id,binding:firstBinding,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(proof.digest,pending.digest)
            do { _ = try await restarted.load(actorID:UUID(),id:pending.id,deadline:.now.advanced(by:.seconds(4)));XCTFail("Actor boundary bypass") }
            catch { XCTAssertEqual(error as? ApprovalError,.notFound) }
            let wrong = try ApprovalBinding(actorID:actor,runID:run,ledgerID:firstBinding.ledgerID,commandHash:Data(repeating:0,count:32))
            do { _ = try await restarted.verify(actorID:actor,id:pending.id,binding:wrong,deadline:.now.advanced(by:.seconds(4)));XCTFail("Changed command accepted") }
            catch { XCTAssertEqual(error as? ApprovalError,.conflict) }
            let concurrentBinding = try await binding("concurrent")
            let contested = try await service.request(concurrentBinding,deadline:.now.advanced(by:.seconds(4)))
            let outcomes = try await client.withConnection(isolation:nil) { blocker in
                var open = true;defer { if open { blocker.close().whenFailure { _ in } } }
                _ = try await blocker.query("BEGIN",logger:Self.logger).collect()
                _ = try await blocker.query("SELECT id FROM approvals WHERE id=\(contested.id) FOR UPDATE",logger:Self.logger).collect()
                async let a = Self.outcome(service,record:contested,response:.approve)
                async let b = Self.outcome(service,record:contested,response:.deny)
                let limit = ContinuousClock.now.advanced(by:.seconds(2));var blocked: Int64 = 0
                repeat {
                    let rows = try await client.query("SELECT count(*)::bigint FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%approvals%FOR UPDATE%'").collect()
                    blocked = try rows[0].decode(Int64.self)
                    if blocked >= 2 { break };try await Task.sleep(for:.milliseconds(10))
                } while ContinuousClock.now < limit
                XCTAssertGreaterThanOrEqual(blocked,2)
                _ = try await blocker.query("ROLLBACK",logger:Self.logger).collect();open = false
                return await [a,b]
            }
            var successes = 0,conflicts = 0
            for outcome in outcomes {
                switch outcome { case .success: successes += 1;case .failure(let error):XCTAssertEqual(error,.conflict);conflicts += 1 }
            }
            XCTAssertEqual(successes,1);XCTAssertEqual(conflicts,1)
            let winner = try await restarted.load(actorID:actor,id:contested.id,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(winner.version,2);XCTAssertTrue([ApprovalDecision.approved,.denied].contains(winner.decision))
            let lateBinding = try await binding("expiry"),late = try await service.request(lateBinding,deadline:.now.advanced(by:.seconds(4)))
            let future = try FixedClock(instant:UTCInstant(secondsSince1970:Double(late.expiresAtMilliseconds)/1_000),timeZone:IANATimeZone(identifier:"Etc/UTC"))
            let expired = try await ApprovalCoordinator(store:store,clock:future).resolve(actorID:actor,id:late.id,response:.approve,principalID:actor,expectedDigest:late.digest,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(expired.decision,.expired);XCTAssertNil(expired.approverID)
            let preserved = try await restarted.load(actorID:actor,id:late.id,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(expired,preserved)
            // A persisted approved fixture has now expired according to DB time.
            // The host clock deliberately remains before expiry.
            let ancientBinding = try await binding("server-expired")
            // PostgreSQL may run in a VM with a different wall clock. Anchor this
            // server-expired fixture to the clock whose expiry check it exercises.
            let databaseTime = try await client.query("SELECT floor(extract(epoch FROM clock_timestamp())*1000)::bigint").collect()
            let now = try databaseTime[0].decode(Int64.self)
            let ancient = try ApprovalRecord(id:UUID(),binding:ancientBinding,requestedAtMilliseconds:now-600_001,
                expiresAtMilliseconds:now-1,decision:.approved,approverID:actor,decidedAtMilliseconds:now-600_000,version:2)
            let hash = ancientBinding.commandHash.map { String(format:"%02x",$0) }.joined()
            let digest = ancient.digest.map { String(format:"%02x",$0) }.joined()
            let requested = ancient.requestedAtMilliseconds,expires = ancient.expiresAtMilliseconds,decided = now-600_000
            _ = try await client.query("""
                INSERT INTO approvals(id,actor_id,run_id,ledger_id,command_hash,approval_digest,decision,approver_id,requested_at,expires_at,decided_at,version)
                VALUES(\(ancient.id),\(actor),\(run),\(ancientBinding.ledgerID),decode(\(hash),'hex'),decode(\(digest),'hex'),'approved',\(actor),
                    to_timestamp(\(Double(requested/1_000)))+\(requested%1_000)*interval '1 millisecond',
                    to_timestamp(\(Double(expires/1_000)))+\(expires%1_000)*interval '1 millisecond',
                    to_timestamp(\(Double(decided/1_000)))+\(decided%1_000)*interval '1 millisecond',2)
                """).collect()
            let oldClock = try FixedClock(instant:UTCInstant(secondsSince1970:Double(requested)/1_000),timeZone:IANATimeZone(identifier:"Etc/UTC"))
            do { _ = try await ApprovalCoordinator(store:store,clock:oldClock).verify(actorID:actor,id:ancient.id,binding:ancientBinding,deadline:.now.advanced(by:.seconds(4)));XCTFail("Database expiry hidden by old host clock") }
            catch { XCTAssertEqual(error as? ApprovalError,.expired) }
            let corruptBinding = try await binding("corrupt")
            let corruptID = UUID(),corruptHash = corruptBinding.commandHash.map { String(format:"%02x",$0) }.joined()
            _ = try await client.query("""
                INSERT INTO approvals(id,actor_id,run_id,ledger_id,command_hash,approval_digest)
                VALUES(\(corruptID),\(actor),\(run),\(corruptBinding.ledgerID),decode(\(corruptHash),'hex'),decode(repeat('00',32),'hex'))
                """).collect()
            do { _ = try await restarted.load(actorID:actor,id:corruptID,deadline:.now.advanced(by:.seconds(4)));XCTFail("Corrupt digest trusted") }
            catch { XCTAssertEqual(error as? ApprovalError,.corruptRecord) }
            let count = try await client.query("SELECT count(*)::bigint FROM approvals WHERE actor_id=\(actor) AND ledger_id=\(firstBinding.ledgerID)").collect()
            XCTAssertEqual(try count[0].decode(Int64.self),1)
        }
    }
}
