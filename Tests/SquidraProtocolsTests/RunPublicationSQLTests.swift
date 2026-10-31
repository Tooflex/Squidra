import Foundation
import PostgresNIO
import SquidraCognition
import SquidraDomain
import SquidraPostgres
import SquidraProtocols
import SquidraWorld
import XCTest

// SAFETY: stateless suite, each scenario owns independent actor/run IDs and local clients.
final class RunPublicationSQLTests: XCTestCase, @unchecked Sendable {
    private static func client() throws -> PostgresClient {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw RunEventStoreError.unavailable }
        return try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
    }
    private static func binding(_ actor:UUID = UUID()) -> AGUIRunBinding { AGUIRunBinding(actorID:actor,runID:UUID(),threadID:UUID(),requestID:UUID()) }
    private static var deadline:ContinuousClock.Instant { .now.advanced(by:.seconds(4)) }
    private static var at:UTCInstant { get throws { try UTCInstant(secondsSince1970:1_700_000_000) } }
    private static func expect(_ expected:RunEventStoreError,_ operation:() async throws -> Void) async {
        do { try await operation();XCTFail("Expected bounded publication failure") }
        catch { XCTAssertEqual(error as? RunEventStoreError,expected) }
    }
    private struct ForgedClaim: RunPublicationClaim { let binding:AGUIRunBinding,executionExpiresAt:UTCInstant }
    private static func answer(_ binding:AGUIRunBinding) throws -> GroundedAnswer {
        let subject = UUID(),at = try Self.at
        let snapshot = WorldStateSnapshot(actorID:binding.actorID,subjectID:subject,validAt:at,knownAt:at,facts:[],projectedThroughSequence:0,availableThroughSequence:0)
        let context = try AnswerEvidenceContext(snapshot:snapshot,expectedActor:binding.actorID,intent:.current,
            clock:FixedClock(instant:at,timeZone:IANATimeZone(identifier:"UTC")),policy:AnswerFreshnessPolicy(maximumObservationAgeSeconds:60,minimumCurrentConfidence:Confidence(0.5)))
        let text = String(decoding:try JSONSerialization.data(withJSONObject:["schemaVersion":"1","claims":[["kind":"unknown","subjectId":subject.uuidString,"citations":[]]]]),as:UTF8.self)
        let response = ModelResponse(schemaVersion:"1",requestID:binding.requestID,modelID:"fixture",modelVersion:"1",text:text,outputTokens:1,costMicroUSD:0)
        return try GroundedAnswerValidator().validate(response,expectedRequestID:binding.requestID,context:context)
    }
    func testConcurrentClaimsOpaqueOwnershipAndUnmanagedStreamIsolation() async throws {
        let client = try Self.client(),other = try Self.client(),binding = Self.binding(),at = try Self.at
        let events = PostgresRunEventStore(client:client,actorID:binding.actorID)
        let a = PostgresRunPublicationStore(client:client,actorID:binding.actorID),b = PostgresRunPublicationStore(client:other,actorID:binding.actorID)
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };group.addTask { await other.run() };defer { group.cancelAll() }
            _ = try await events.create(binding,retentionSeconds:3600,deadline:Self.deadline)
            @Sendable func compete(_ store:PostgresRunPublicationStore) async throws -> (any RunPublicationClaim)? {
                do { return try await store.claim(binding,maximumExecutionSeconds:180,at:at,deadline:Self.deadline) }
                catch RunEventStoreError.conflict { return nil }
            }
            async let one = compete(a)
            async let two = compete(b)
            let claims = try await [one,two].compactMap { $0 }
            XCTAssertEqual(claims.count,1)
            let claim = try XCTUnwrap(claims.first)
            XCTAssertEqual(claim.binding,binding)
            XCTAssertGreaterThan(claim.executionExpiresAt.secondsSince1970,Date().timeIntervalSince1970)
            await Self.expect(.conflict) { _ = try await a.claim(binding,maximumExecutionSeconds:180,at:at,deadline:Self.deadline) }
            await Self.expect(.conflict) { _ = try await events.append(binding,expectedNextSequence:2,events:[AGUIEvent.finished(binding:binding,at:at)],deadline:Self.deadline) }
            let forged = ForgedClaim(binding:binding,executionExpiresAt:claim.executionExpiresAt)
            await Self.expect(.invalidRequest) { _ = try await b.finish(forged,outcome:.cancelled,at:at,deadline:Self.deadline) }
            let foreign = PostgresRunPublicationStore(client:other,actorID:UUID())
            await Self.expect(.notFound) { _ = try await foreign.finish(claim,outcome:.cancelled,at:at,deadline:Self.deadline) }
            await Self.expect(.notFound) { _ = try await foreign.status(actorID:binding.actorID,runID:binding.runID,deadline:Self.deadline) }
            let running = try await b.status(actorID:binding.actorID,runID:binding.runID,deadline:Self.deadline)
            XCTAssertEqual(running.phase,.running);XCTAssertEqual(running.stream.nextSequence,2);XCTAssertFalse(running.leaseExpired)
            let cancelled = try await b.finish(claim,outcome:.cancelled,at:at,deadline:Self.deadline)
            XCTAssertEqual(cancelled.phase,.cancelled);XCTAssertTrue(cancelled.stream.isTerminal)
            await Self.expect(.conflict) { _ = try await a.finish(claim,outcome:.failed(.executionFailed),at:at,deadline:Self.deadline) }
            _ = try await client.query("UPDATE run_event_streams SET publication_phase='failed' WHERE run_id=\(binding.runID)").collect()
            await Self.expect(.corruptRecord) { _ = try await a.status(actorID:binding.actorID,runID:binding.runID,deadline:Self.deadline) }
            let legacy = Self.binding(binding.actorID)
            _ = try await events.create(legacy,retentionSeconds:3600,deadline:Self.deadline)
            _ = try await events.append(legacy,expectedNextSequence:1,events:[AGUIEvent.started(binding:legacy,at:at),AGUIEvent.finished(binding:legacy,at:at)],deadline:Self.deadline)
            let status = try await a.status(actorID:binding.actorID,runID:legacy.runID,deadline:Self.deadline)
            XCTAssertEqual(status.phase,.unmanaged);XCTAssertTrue(status.stream.isTerminal)
            await Self.expect(.conflict) { _ = try await a.claim(legacy,maximumExecutionSeconds:1,at:at,deadline:Self.deadline) }
            let short = Self.binding(binding.actorID)
            _ = try await events.create(short,retentionSeconds:5,deadline:Self.deadline)
            await Self.expect(.expired) { _ = try await a.claim(short,maximumExecutionSeconds:1,at:at,deadline:Self.deadline) }
            let intact = try await events.page(actorID:binding.actorID,runID:short.runID,cursor:nil,limit:32,deadline:Self.deadline)
            XCTAssertTrue(intact.records.isEmpty)
        }
    }
    func testGroundedTerminalPublicationIsAtomicAcrossDatabaseFailureAndReopen() async throws {
        let client = try Self.client(),other = try Self.client(),binding = Self.binding(),at = try Self.at,answer = try Self.answer(binding)
        let events = PostgresRunEventStore(client:client,actorID:binding.actorID),publication = PostgresRunPublicationStore(client:client,actorID:binding.actorID)
        let reopened = PostgresRunPublicationStore(client:other,actorID:binding.actorID)
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };group.addTask { await other.run() };defer { group.cancelAll() }
            _ = try await events.create(binding,retentionSeconds:3600,deadline:Self.deadline)
            let claim = try await publication.claim(binding,maximumExecutionSeconds:180,at:at,deadline:Self.deadline)
            // DDL identifiers/literal contain only an internally generated UUID.
            let name = "test_publication_"+binding.runID.uuidString.replacingOccurrences(of:"-",with:"").lowercased()
            _ = try await client.query(PostgresQuery(unsafeSQL:"CREATE FUNCTION "+name+"() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'Injected terminal failure'; END; $$")).collect()
            _ = try await client.query(PostgresQuery(unsafeSQL:"CREATE TRIGGER "+name+" BEFORE INSERT ON run_events FOR EACH ROW WHEN (NEW.run_id='"+binding.runID.uuidString+"'::uuid AND NEW.sequence=4) EXECUTE FUNCTION "+name+"()")).collect()
            await Self.expect(.unavailable) { _ = try await publication.finish(claim,outcome:.answer(answer,messageID:UUID()),at:at,deadline:Self.deadline) }
            let unchanged = try await reopened.status(actorID:binding.actorID,runID:binding.runID,deadline:Self.deadline)
            XCTAssertEqual(unchanged.phase,.running);XCTAssertEqual(unchanged.stream.nextSequence,2);XCTAssertFalse(unchanged.stream.isTerminal)
            _ = try await client.query(PostgresQuery(unsafeSQL:"DROP TRIGGER "+name+" ON run_events")).collect()
            _ = try await client.query(PostgresQuery(unsafeSQL:"DROP FUNCTION "+name+"()")).collect()
            let finished = try await reopened.finish(claim,outcome:.answer(answer,messageID:UUID()),at:at,deadline:Self.deadline)
            XCTAssertEqual(finished.phase,.succeeded);XCTAssertEqual(finished.stream.nextSequence,7)
            let reread = try await publication.status(actorID:binding.actorID,runID:binding.runID,deadline:Self.deadline)
            XCTAssertEqual(reread.phase,.succeeded);XCTAssertEqual(reread.stream,finished.stream)
            let cursor = try AGUIResumeCursor(actorID:binding.actorID,runID:binding.runID,afterSequence:1).encoded()
            let page = try await events.page(actorID:binding.actorID,runID:binding.runID,cursor:cursor,limit:32,deadline:Self.deadline)
            XCTAssertEqual(page.records.count,5);XCTAssertFalse(page.hasMore)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with:page.records[0].json) as? [String:Any])
            let proof = try XCTUnwrap(object["value"] as? [String:Any]);XCTAssertEqual(proof["status"] as? String,"unknown")
            XCTAssertEqual((proof["actorId"] as? String).flatMap(UUID.init(uuidString:)),binding.actorID)
            await Self.expect(.conflict) { _ = try await publication.finish(claim,outcome:.answer(answer,messageID:UUID()),at:at,deadline:Self.deadline) }
        }
    }
    func testExpiredLeaseRecoveryDoesNotReexecuteAndLateOrExpiredPublicationFails() async throws {
        let client = try Self.client(),binding = Self.binding(),at = try Self.at
        let events = PostgresRunEventStore(client:client,actorID:binding.actorID),publication = PostgresRunPublicationStore(client:client,actorID:binding.actorID)
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            _ = try await events.create(binding,retentionSeconds:3600,deadline:Self.deadline)
            let claim = try await publication.claim(binding,maximumExecutionSeconds:180,at:at,deadline:Self.deadline)
            await Self.expect(.conflict) { _ = try await publication.recoverExpired(actorID:binding.actorID,runID:binding.runID,at:at,deadline:Self.deadline) }
            _ = try await client.query("UPDATE run_event_streams SET created_at=clock_timestamp()-interval '2 hours',execution_lease_until=clock_timestamp()-interval '1 hour' WHERE run_id=\(binding.runID)").collect()
            let stale = try await publication.status(actorID:binding.actorID,runID:binding.runID,deadline:Self.deadline)
            XCTAssertTrue(stale.leaseExpired);XCTAssertEqual(stale.phase,.running)
            await Self.expect(.conflict) { _ = try await publication.finish(claim,outcome:.cancelled,at:at,deadline:Self.deadline) }
            let recovered = try await publication.recoverExpired(actorID:binding.actorID,runID:binding.runID,at:at,deadline:Self.deadline)
            XCTAssertEqual(recovered.phase,.recoveryRequired);XCTAssertEqual(recovered.stream.nextSequence,3)
            let page = try await events.page(actorID:binding.actorID,runID:binding.runID,cursor:nil,limit:32,deadline:Self.deadline)
            XCTAssertEqual(page.records.count,2)
            let error = try XCTUnwrap(JSONSerialization.jsonObject(with:page.records[1].json) as? [String:Any])
            XCTAssertEqual(error["code"] as? String,AGUIPublicFailure.recoveryRequired.rawValue)
            await Self.expect(.conflict) { _ = try await publication.recoverExpired(actorID:binding.actorID,runID:binding.runID,at:at,deadline:Self.deadline) }
            await Self.expect(.conflict) { _ = try await publication.finish(claim,outcome:.cancelled,at:at,deadline:Self.deadline) }
            _ = try await client.query("UPDATE run_event_streams SET created_at=clock_timestamp()-interval '3 hours',execution_lease_until=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE run_id=\(binding.runID)").collect()
            await Self.expect(.expired) { _ = try await publication.status(actorID:binding.actorID,runID:binding.runID,deadline:Self.deadline) }
            await Self.expect(.expired) { _ = try await publication.recoverExpired(actorID:binding.actorID,runID:binding.runID,at:at,deadline:Self.deadline) }
            await Self.expect(.expired) { _ = try await publication.finish(claim,outcome:.cancelled,at:at,deadline:Self.deadline) }
        }
    }
}
