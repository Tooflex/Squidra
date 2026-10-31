import Foundation
import PostgresNIO
import SquidraCognition
import SquidraDomain
import SquidraPostgres
@testable import SquidraProtocols
import SquidraWorld
import XCTest

// SAFETY: stateless suite; each test owns separate actors/runs in the isolated database.
final class RunEventSQLTests: XCTestCase, @unchecked Sendable {
    private static func client() throws -> PostgresClient {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            throw RunEventStoreError.unavailable
        }
        return try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
    }
    private static func binding(_ actor: UUID = UUID()) -> AGUIRunBinding {
        AGUIRunBinding(actorID:actor,runID:UUID(),threadID:UUID(),requestID:UUID())
    }
    private static var deadline: ContinuousClock.Instant { .now.advanced(by:.seconds(4)) }
    private static var at: UTCInstant { get throws { try UTCInstant(secondsSince1970:1_700_000_000) } }
    private static func events(_ binding:AGUIRunBinding) throws -> [AGUIEvent] {
        let subject = UUID(),at = try Self.at
        let snapshot = WorldStateSnapshot(actorID:binding.actorID,subjectID:subject,validAt:at,knownAt:at,facts:[],projectedThroughSequence:0,availableThroughSequence:0)
        let context = try AnswerEvidenceContext(snapshot:snapshot,expectedActor:binding.actorID,intent:.current,
            clock:FixedClock(instant:at,timeZone:IANATimeZone(identifier:"UTC")),policy:AnswerFreshnessPolicy(maximumObservationAgeSeconds:60,minimumCurrentConfidence:Confidence(0.5)))
        let text = String(decoding:try JSONSerialization.data(withJSONObject:["schemaVersion":"1","claims":[["kind":"unknown","subjectId":subject.uuidString,"citations":[]]]]),as:UTF8.self)
        let response = ModelResponse(schemaVersion:"1",requestID:binding.requestID,modelID:"fixture",modelVersion:"1",text:text,outputTokens:1,costMicroUSD:0)
        let answer = try GroundedAnswerValidator().validate(response,expectedRequestID:binding.requestID,context:context)
        return try [AGUIEvent.started(binding:binding,at:at)]+AGUIEvent.answer(answer,binding:binding,messageID:UUID(),at:at)+[AGUIEvent.finished(binding:binding,at:at)]
    }
    private static func expect(_ expected:RunEventStoreError,_ operation:() async throws -> Void) async {
        do { try await operation();XCTFail("Expected bounded store failure") }
        catch { XCTAssertEqual(error as? RunEventStoreError,expected) }
    }
    func testDurableReplayScopeCursorAndExpiryAcrossTwoClients() async throws {
        let first = try Self.client(),second = try Self.client(),binding = Self.binding(),events = try Self.events(binding)
        let store = PostgresRunEventStore(client:first,actorID:binding.actorID),reopened = PostgresRunEventStore(client:second,actorID:binding.actorID)
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await first.run() };group.addTask { await second.run() };defer { group.cancelAll() }
            let created = try await store.create(binding,retentionSeconds:3600,deadline:Self.deadline)
            let duplicate = try await reopened.create(binding,retentionSeconds:3600,deadline:Self.deadline)
            XCTAssertEqual(created,duplicate)
            await Self.expect(.conflict) { _ = try await reopened.create(binding,retentionSeconds:7200,deadline:Self.deadline) }
            let changed = AGUIRunBinding(actorID:binding.actorID,runID:binding.runID,threadID:UUID(),requestID:binding.requestID)
            await Self.expect(.conflict) { _ = try await reopened.create(changed,retentionSeconds:3600,deadline:Self.deadline) }
            _ = try await store.append(binding,expectedNextSequence:1,events:[events[0]],deadline:Self.deadline)
            await Self.expect(.conflict) { _ = try await reopened.append(binding,expectedNextSequence:1,events:[events[0]],deadline:Self.deadline) }
            let completed = try await store.append(binding,expectedNextSequence:2,events:Array(events.dropFirst()),deadline:Self.deadline)
            XCTAssertEqual(completed.nextSequence,7);XCTAssertTrue(completed.isTerminal);XCTAssertEqual(completed.expiresAt,created.expiresAt)
            var cursor: String?,all:[AGUIReplayRecord] = []
            while true {
                let page = try await reopened.page(actorID:binding.actorID,runID:binding.runID,cursor:cursor,limit:2,deadline:Self.deadline)
                XCTAssertEqual(page.throughSequence,6);all += page.records;cursor = page.nextCursor
                if !page.hasMore { break }
            }
            XCTAssertEqual(all.map(\.sequence),[1,2,3,4,5,6])
            let repeated = try await store.page(actorID:binding.actorID,runID:binding.runID,cursor:nil,limit:32,deadline:Self.deadline)
            XCTAssertEqual(try all.map { try $0.encodedSSE() },try repeated.records.map { try $0.encodedSSE() })
            let caughtUp = try await reopened.page(actorID:binding.actorID,runID:binding.runID,cursor:cursor,limit:2,deadline:Self.deadline)
            XCTAssertTrue(caughtUp.records.isEmpty);XCTAssertFalse(caughtUp.hasMore)
            await Self.expect(.notFound) { _ = try await reopened.page(actorID:UUID(),runID:binding.runID,cursor:"malformed",limit:2,deadline:Self.deadline) }
            await Self.expect(.notFound) { _ = try await reopened.page(actorID:binding.actorID,runID:UUID(),cursor:"malformed",limit:2,deadline:Self.deadline) }
            await Self.expect(.invalidRequest) { _ = try await reopened.page(actorID:binding.actorID,runID:binding.runID,cursor:"malformed",limit:2,deadline:Self.deadline) }
            let future = try AGUIResumeCursor(actorID:binding.actorID,runID:binding.runID,afterSequence:7).encoded()
            await Self.expect(.invalidRequest) { _ = try await reopened.page(actorID:binding.actorID,runID:binding.runID,cursor:future,limit:2,deadline:Self.deadline) }
            await Self.expect(.conflict) { _ = try await reopened.append(binding,expectedNextSequence:7,events:[events[5]],deadline:Self.deadline) }
            _ = try await first.query("UPDATE run_event_streams SET created_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE run_id=\(binding.runID)").collect()
            await Self.expect(.expired) { _ = try await reopened.page(actorID:binding.actorID,runID:binding.runID,cursor:nil,limit:2,deadline:Self.deadline) }
            await Self.expect(.expired) { _ = try await reopened.create(binding,retentionSeconds:3600,deadline:Self.deadline) }
            await Self.expect(.expired) { _ = try await reopened.append(binding,expectedNextSequence:7,events:[events[5]],deadline:Self.deadline) }
        }
    }
    func testAtomicBatchCASImmutableEventsAndCorruption() async throws {
        let client = try Self.client(),other = try Self.client(),binding = Self.binding(),events = try Self.events(binding)
        let store = PostgresRunEventStore(client:client,actorID:binding.actorID),rival = PostgresRunEventStore(client:other,actorID:binding.actorID)
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };group.addTask { await other.run() };defer { group.cancelAll() }
            _ = try await store.create(binding,retentionSeconds:3600,deadline:Self.deadline)
            // The first item would be valid; the second is not. Neither may publish.
            await Self.expect(.invalidRequest) { _ = try await store.append(binding,expectedNextSequence:1,events:[events[0],events[0]],deadline:Self.deadline) }
            let empty = try await rival.page(actorID:binding.actorID,runID:binding.runID,cursor:nil,limit:32,deadline:Self.deadline)
            XCTAssertEqual(empty.info.nextSequence,1);XCTAssertTrue(empty.records.isEmpty)
            _ = try await store.append(binding,expectedNextSequence:1,events:[events[0]],deadline:Self.deadline)
            // Force a database error after the first INSERT, not just preflight rejection.
            let triggerName = "test_run_events_"+binding.runID.uuidString.replacingOccurrences(of:"-",with:"").lowercased()
            let setup = "CREATE FUNCTION "+triggerName+"() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'Injected append failure'; END; $$; CREATE TRIGGER "+triggerName+" BEFORE INSERT ON run_events FOR EACH ROW WHEN (NEW.run_id='"+binding.runID.uuidString+"'::uuid AND NEW.sequence=3) EXECUTE FUNCTION "+triggerName+"()"
            for statement in setup.components(separatedBy:"; CREATE TRIGGER ").enumerated() {
                let sql = statement.offset == 0 ? statement.element : "CREATE TRIGGER "+statement.element
                _ = try await client.query(PostgresQuery(unsafeSQL:sql)).collect()
            }
            await Self.expect(.unavailable) { _ = try await store.append(binding,expectedNextSequence:2,events:Array(events[1...2]),deadline:Self.deadline) }
            _ = try await client.query(PostgresQuery(unsafeSQL:"DROP TRIGGER "+triggerName+" ON run_events")).collect()
            _ = try await client.query(PostgresQuery(unsafeSQL:"DROP FUNCTION "+triggerName+"()")).collect()
            let rolledBack = try await rival.page(actorID:binding.actorID,runID:binding.runID,cursor:nil,limit:32,deadline:Self.deadline)
            XCTAssertEqual(rolledBack.info.nextSequence,2);XCTAssertEqual(rolledBack.records.count,1)
            let failed = try AGUIEvent.failed(binding:binding,at:Self.at,code:.executionFailed)
            @Sendable func compete(_ contender:PostgresRunEventStore,_ event:AGUIEvent) async -> RunEventStoreError? {
                do { _ = try await contender.append(binding,expectedNextSequence:2,events:[event],deadline:Self.deadline);return nil }
                catch { return error as? RunEventStoreError ?? .unavailable }
            }
            async let a = compete(store,failed)
            async let b = compete(rival,events[5])
            let outcomes = await [a,b]
            XCTAssertEqual(outcomes.filter { $0 == nil }.count,1);XCTAssertEqual(outcomes.filter { $0 == .conflict }.count,1)
            let final = try await store.page(actorID:binding.actorID,runID:binding.runID,cursor:nil,limit:32,deadline:Self.deadline)
            XCTAssertEqual(final.records.count,2);XCTAssertTrue(final.info.isTerminal)
            do {
                _ = try await client.query("UPDATE run_events SET payload=payload WHERE run_id=\(binding.runID)").collect()
                XCTFail("Immutable event update succeeded")
            } catch { XCTAssertTrue(error is PSQLError) }
            _ = try await client.query("DELETE FROM run_events WHERE run_id=\(binding.runID) AND sequence=1").collect()
            await Self.expect(.corruptRecord) { _ = try await store.page(actorID:binding.actorID,runID:binding.runID,cursor:nil,limit:32,deadline:Self.deadline) }
        }
    }
    func testBoundedBytesEventsAndCancelledWriterLeaveNoPartialHistory() async throws {
        let client = try Self.client(),binding = Self.binding(),store = PostgresRunEventStore(client:client,actorID:binding.actorID)
        let message = UUID().uuidString.lowercased()
        func event(_ kind:AGUIEventKind,_ fields:[String:Any]) throws -> AGUIEvent {
            var fields = fields;fields["type"] = kind.rawValue
            return try AGUIEvent(binding:binding,kind:kind,json:JSONSerialization.data(withJSONObject:fields))
        }
        let start = try AGUIEvent.started(binding:binding,at:Self.at),textStart = try event(.textStart,["messageId":message,"role":"assistant"])
        // Internal test-only producer stresses storage bounds, not a public raw-delta API.
        let large = try event(.textContent,["messageId":message,"delta":String(repeating:"a",count:60_000)])
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            _ = try await store.create(binding,retentionSeconds:3600,deadline:Self.deadline)
            _ = try await store.append(binding,expectedNextSequence:1,events:[start,textStart],deadline:Self.deadline)
            await Self.expect(.invalidRequest) { _ = try await store.append(binding,expectedNextSequence:3,events:Array(repeating:large,count:5),deadline:Self.deadline) }
            var next: Int64 = 3
            for _ in 0..<4 { _ = try await store.append(binding,expectedNextSequence:next,events:Array(repeating:large,count:4),deadline:Self.deadline);next += 4 }
            await Self.expect(.limitExceeded) { _ = try await store.append(binding,expectedNextSequence:next,events:[large,large],deadline:Self.deadline) }
            let page = try await store.page(actorID:binding.actorID,runID:binding.runID,cursor:nil,limit:32,deadline:Self.deadline)
            XCTAssertEqual(page.info.nextSequence,19);XCTAssertEqual(page.records.count,18)
            await Self.expect(.timedOut) { _ = try await store.append(binding,expectedNextSequence:next,events:[large],deadline:.now.advanced(by:.seconds(-1))) }
            let countBinding = Self.binding(binding.actorID),countMessage = UUID().uuidString.lowercased()
            func countEvent(_ kind:AGUIEventKind,_ fields:[String:Any]) throws -> AGUIEvent {
                var fields = fields;fields["type"] = kind.rawValue
                return try AGUIEvent(binding:countBinding,kind:kind,json:JSONSerialization.data(withJSONObject:fields))
            }
            _ = try await store.create(countBinding,retentionSeconds:3600,deadline:Self.deadline)
            _ = try await store.append(countBinding,expectedNextSequence:1,events:[AGUIEvent.started(binding:countBinding,at:Self.at),countEvent(.textStart,["messageId":countMessage])],deadline:Self.deadline)
            let delta = try countEvent(.textContent,["messageId":countMessage,"delta":""])
            var countNext: Int64 = 3
            while countNext < 127 {
                let count = min(16,Int(127-countNext))
                _ = try await store.append(countBinding,expectedNextSequence:countNext,events:Array(repeating:delta,count:count),deadline:Self.deadline)
                countNext += Int64(count)
            }
            await Self.expect(.invalidRequest) { _ = try await store.append(countBinding,expectedNextSequence:127,events:[delta,delta],deadline:Self.deadline) }
            let terminal = try await store.append(countBinding,expectedNextSequence:127,events:[countEvent(.textEnd,["messageId":countMessage]),AGUIEvent.finished(binding:countBinding,at:Self.at)],deadline:Self.deadline)
            XCTAssertEqual(terminal.nextSequence,129);XCTAssertTrue(terminal.isTerminal)
            let smallBinding = Self.binding(binding.actorID),small = PostgresRunEventStore(client:client,actorID:binding.actorID)
            _ = try await small.create(smallBinding,retentionSeconds:3600,deadline:Self.deadline)
            let smallStart = try AGUIEvent.started(binding:smallBinding,at:Self.at)
            let task = Task { () throws -> AGUIRunStreamInfo in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await small.append(smallBinding,expectedNextSequence:1,events:[smallStart],deadline:Self.deadline)
            }
            do { _ = try await task.value;XCTFail("Cancelled writer succeeded") }
            catch { XCTAssertEqual(error as? RunEventStoreError,.cancelled) }
            let unchanged = try await small.page(actorID:binding.actorID,runID:smallBinding.runID,cursor:nil,limit:32,deadline:Self.deadline)
            XCTAssertEqual(unchanged.info.nextSequence,1)
        }
    }
}
