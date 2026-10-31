import Foundation
import Logging
import PostgresNIO
import SquidraDomain
import SquidraPostgres
import SquidraWorld
import XCTest

// SAFETY: stateless suite with an isolated real database; no shared mutable state.
final class WorldJournalSQLTests: XCTestCase, @unchecked Sendable {
    private static let logger = Logger(label:"squidra.journal-test",factory:{ _ in SwiftLogNoOpLogHandler() })
    private static func clone(_ event: WorldEventDraft, payload: Data? = nil, entities: [UUID]? = nil, times: JournalTimes? = nil) throws -> WorldEventDraft {
        try WorldEventDraft(actorID:event.actorID,streamID:event.streamID,entityIDs:entities ?? event.entityIDs,type:event.type,times:times ?? event.times,
            sourceID:event.sourceID,confidence:event.confidence,payloadVersion:event.payloadVersion,payload:payload ?? event.payload.bytes,
            causationID:event.causationID,correlationID:UUID())
    }
    private static func appendResult(_ store: PostgresWorldRepository, event: WorldEventDraft, key: String) async -> Result<JournalAppend,WorldJournalError> {
        do { return .success(try await store.append(event,expectedVersion:0,idempotencyKey:key,deadline:.now.advanced(by:.seconds(4)))) }
        catch { return .failure(error as? WorldJournalError ?? .unavailable) }
    }
    private static func waitForLocks(_ client: PostgresClient, pattern: String, count: Int64) async throws -> Int64 {
        let limit = ContinuousClock.now.advanced(by:.seconds(1));var blocked: Int64 = 0
        repeat {
            let rows = try await client.query("SELECT count(*)::bigint FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE \(pattern)").collect()
            blocked = try rows[0].decode(Int64.self)
            if blocked >= count { break };try await Task.sleep(for:.milliseconds(10))
        } while ContinuousClock.now < limit
        return blocked
    }
    func testRealAppendReplayConcurrentCASCorrectionsAndStablePagination() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let portText = env["SQUIDRA_TEST_DB_PORT"],let port = Int(portText),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            XCTFail("Run through the isolated SQD-016 database helper");return
        }
        let client = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
        let store = PostgresWorldRepository(client:client),fixture = try JournalFixture.load(),actor = fixture.actorID
        let entityA = fixture.events[0].draft.entityIDs[0],entityB = fixture.events[1].draft.entityIDs[0]
        @Sendable func extra(stream: UUID, entity: UUID, actorID: UUID? = nil, payload: String = #"{"n":1}"#, cause: UUID? = nil) throws -> WorldEventDraft {
            try WorldEventDraft(actorID:actorID ?? actor,streamID:stream,entityIDs:[entity],type:"fixture.concurrent",times:fixture.events[0].draft.times,
                sourceID:"fixture:concurrency",confidence:Confidence(1),payloadVersion:1,payload:Data(payload.utf8),causationID:cause,correlationID:UUID())
        }
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            for entity in [entityA,entityB] { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect() }
            let first = try await store.append(fixture.events[0].draft,expectedVersion:0,idempotencyKey:"fixture:1",deadline:.now.advanced(by:.seconds(4)))
            XCTAssertTrue(first.created);XCTAssertNil(first.event.draft.times.occurredAt)
            XCTAssertEqual(first.event.draft.times.observedMicroseconds,fixture.events[0].draft.times.observedMicroseconds)
            XCTAssertEqual(first.event.draft.times.timeZone.identifier,"Europe/Paris")
            let equivalent = try Self.clone(fixture.events[0].draft,payload:Data(#"{"schemaVersion":"1","label":"Room A"}"#.utf8))
            let replay = try await store.append(equivalent,expectedVersion:0,idempotencyKey:"fixture:1",deadline:.now.advanced(by:.seconds(4)))
            XCTAssertFalse(replay.created);XCTAssertEqual(replay.event,first.event)
            for changed in try [Self.clone(fixture.events[0].draft,payload:Data(#"{"schemaVersion":"1","label":"changed"}"#.utf8)),
                                Self.clone(fixture.events[0].draft,entities:[entityB]),
                                Self.clone(fixture.events[0].draft,times:JournalTimes(occurredMicroseconds:nil,observedMicroseconds:first.event.draft.times.observedMicroseconds,timeZone:IANATimeZone(identifier:"Etc/UTC")))] {
                do { _ = try await store.append(changed,expectedVersion:0,idempotencyKey:"fixture:1",deadline:.now.advanced(by:.seconds(4)));XCTFail("Key reuse changed command") }
                catch { XCTAssertEqual(error as? WorldJournalError,.idempotencyConflict) }
            }
            do { _ = try await store.append(Self.clone(fixture.events[0].draft),expectedVersion:2,idempotencyKey:"wrong-version",deadline:.now.advanced(by:.seconds(4)));XCTFail("Wrong version accepted") }
            catch { XCTAssertEqual(error as? WorldJournalError,.versionConflict) }
            // A journal key belongs to one actor/stream; the second stream may reuse it.
            let second = try await store.append(fixture.events[1].draft,expectedVersion:0,idempotencyKey:"fixture:1",deadline:.now.advanced(by:.seconds(4)))
            let snapshot = try await store.page(actorID:actor,limit:1,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(snapshot.events.map(\.draft.id),[first.event.draft.id])
            let cursor = try XCTUnwrap(snapshot.next)
            _ = try await store.append(fixture.events[2].draft,expectedVersion:1,idempotencyKey:"fixture:3",deadline:.now.advanced(by:.seconds(4)))
            _ = try await store.append(fixture.events[3].draft,expectedVersion:1,idempotencyKey:"fixture:4",deadline:.now.advanced(by:.seconds(4)))
            let remainder = try await store.page(actorID:actor,cursor:cursor,limit:1,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(remainder.events.map(\.draft.id),[second.event.draft.id]);XCTAssertNil(remainder.next)
            XCTAssertEqual(remainder.throughSequence,snapshot.throughSequence)
            var records: [JournalEvent] = [],next: JournalCursor?
            repeat {
                let page = try await store.page(actorID:actor,cursor:next,limit:2,deadline:.now.advanced(by:.seconds(4)))
                records += page.events;next = page.next
            } while next != nil
            XCTAssertEqual(records.count,4)
            let rebuilt = LabelFixtureProjector(actorID:actor),duplicate = LabelFixtureProjector(actorID:actor)
            for event in records { try await rebuilt.apply(event);try await duplicate.apply(event);try await duplicate.apply(event) }
            let a = try await rebuilt.checkpoint(),b = try await duplicate.checkpoint()
            XCTAssertEqual(JournalFixture.hash(a),fixture.expectedSHA256);XCTAssertEqual(a.state.bytes,b.state.bytes)
            XCTAssertTrue(String(decoding:records[0].draft.payload.bytes,as:UTF8.self).contains("Room A"))
            do { _ = try await client.query("UPDATE world_events SET source_id='forged' WHERE event_id=\(first.event.draft.id)").collect();XCTFail("Journal updated") }
            catch { let postgres = try XCTUnwrap(error as? PSQLError);XCTAssertEqual(postgres.serverInfo?[.sqlState],"55000") }
            let stream = UUID(),one = try extra(stream:stream,entity:entityA),two = try extra(stream:stream,entity:entityA,payload:#"{"n":2}"#)
            let outcomes = try await client.withConnection(isolation:nil) { blocker in
                var open = true;defer { if open { blocker.close().whenFailure { _ in } } }
                _ = try await blocker.query("BEGIN",logger:Self.logger).collect()
                _ = try await blocker.query("SELECT pg_advisory_xact_lock(hashtextextended(\(actor.uuidString.lowercased()),1936818035))",logger:Self.logger).collect()
                async let a = Self.appendResult(store,event:one,key:"concurrent-a")
                async let b = Self.appendResult(store,event:two,key:"concurrent-b")
                let blocked = try await Self.waitForLocks(client,pattern:"%pg_advisory_xact_lock%",count:2)
                XCTAssertGreaterThanOrEqual(blocked,2)
                _ = try await blocker.query("ROLLBACK",logger:Self.logger).collect();open = false
                return await [a,b]
            }
            var winners = 0,conflicts = 0
            for result in outcomes { switch result {
            case .success(let append):XCTAssertTrue(append.created);winners += 1
            case .failure(let error):XCTAssertEqual(error,.versionConflict);conflicts += 1
            } }
            XCTAssertEqual(winners,1);XCTAssertEqual(conflicts,1)
            let beforeLate = try await store.page(actorID:actor,deadline:.now.advanced(by:.seconds(4)))
            let lateA = try extra(stream:UUID(),entity:entityA),lateB = try extra(stream:UUID(),entity:entityB)
            let late = try await client.withConnection(isolation:nil) { blocker in
                var open = true;defer { if open { blocker.close().whenFailure { _ in } } }
                _ = try await blocker.query("BEGIN",logger:Self.logger).collect()
                _ = try await blocker.query("SELECT id FROM world_entities WHERE actor_id=\(actor) AND id=\(entityA) FOR UPDATE",logger:Self.logger).collect()
                async let a = store.append(lateA,expectedVersion:0,idempotencyKey:"late-a",deadline:.now.advanced(by:.seconds(4)))
                let firstBlocked = try await Self.waitForLocks(client,pattern:"%INSERT INTO world_events%",count:1)
                XCTAssertGreaterThanOrEqual(firstBlocked,1)
                async let b = store.append(lateB,expectedVersion:0,idempotencyKey:"late-b",deadline:.now.advanced(by:.seconds(4)))
                let secondBlocked = try await Self.waitForLocks(client,pattern:"%pg_advisory_xact_lock%",count:1)
                XCTAssertGreaterThanOrEqual(secondBlocked,1)
                let during = try await store.page(actorID:actor,deadline:.now.advanced(by:.seconds(4)))
                XCTAssertEqual(during.throughSequence,beforeLate.throughSequence)
                _ = try await blocker.query("ROLLBACK",logger:Self.logger).collect();open = false
                return try await [a,b]
            }
            XCTAssertLessThan(late[0].event.sequence,late[1].event.sequence)
            let tail = try await store.page(actorID:actor,afterSequence:beforeLate.throughSequence,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(tail.events.map(\.draft.id),[lateA.id,lateB.id])
            let frozen = try JournalCursor(actorID:actor,afterSequence:beforeLate.throughSequence,throughSequence:beforeLate.throughSequence)
            let stillEmpty = try await store.page(actorID:actor,cursor:frozen,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertTrue(stillEmpty.events.isEmpty)
            do { _ = try await store.page(actorID:UUID(),cursor:cursor,deadline:.now.advanced(by:.seconds(4)));XCTFail("Cross-actor cursor accepted") }
            catch { XCTAssertEqual(error as? WorldJournalError,.invalidCursor) }
            let future = try JournalCursor(actorID:actor,afterSequence:0,throughSequence:Int64.max)
            do { _ = try await store.page(actorID:actor,cursor:future,deadline:.now.advanced(by:.seconds(4)));XCTFail("Future cursor allowed moving snapshot") }
            catch { XCTAssertEqual(error as? WorldJournalError,.invalidCursor) }
            for payload in [#"{"n":1e308}"#,#"{"n":1e-200}"#] {
                do { _ = try await store.append(extra(stream:UUID(),entity:entityA,payload:payload),expectedVersion:0,idempotencyKey:UUID().uuidString,deadline:.now.advanced(by:.seconds(4)));XCTFail("Non-roundtrippable JSONB accepted") }
                catch { XCTAssertEqual(error as? WorldJournalError,.invalidEvent) }
            }
            let otherActor = UUID(),otherEntity = UUID()
            _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(otherEntity),\(otherActor),'fixture')").collect()
            for invalid in try [extra(stream:UUID(),entity:entityA,actorID:otherActor),extra(stream:UUID(),entity:otherEntity,actorID:otherActor,cause:first.event.draft.id)] {
                do { _ = try await store.append(invalid,expectedVersion:0,idempotencyKey:"foreign-scope",deadline:.now.advanced(by:.seconds(4)));XCTFail("Foreign actor reference accepted") }
                catch { XCTAssertEqual(error as? WorldJournalError,.notFound) }
            }
            let foreign = try extra(stream:UUID(),entity:otherEntity,actorID:otherActor)
            _ = try await store.append(foreign,expectedVersion:0,idempotencyKey:"fixture:1",deadline:.now.advanced(by:.seconds(4)))
            let foreignPage = try await store.page(actorID:otherActor,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(foreignPage.events.map(\.draft.id),[foreign.id])
            for payload in ["{}",#"{"journalSchemaVersion":"2","timeZone":"Etc/UTC","data":{}}"#] {
                let legacyActor = UUID(),legacyEntity = UUID()
                _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(legacyEntity),\(legacyActor),'fixture')").collect()
                _ = try await client.query("""
                    INSERT INTO world_events(event_id,actor_id,stream_id,stream_version,idempotency_key,entity_ids,event_type,observed_at,source_id,confidence,payload_version,payload,correlation_id)
                    VALUES(\(UUID()),\(legacyActor),\(UUID()),1,'legacy',\([legacyEntity]),'fixture.legacy',clock_timestamp(),'fixture:legacy',1,1,\(payload)::jsonb,\(UUID()))
                    """).collect()
                do { _ = try await store.page(actorID:legacyActor,deadline:.now.advanced(by:.seconds(4)));XCTFail("Unsupported envelope acquired invented metadata") }
                catch { XCTAssertEqual(error as? WorldJournalError,.unsupportedEvent) }
            }

        }
    }
}
