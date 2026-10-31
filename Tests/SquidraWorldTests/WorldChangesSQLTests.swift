import Foundation
import PostgresNIO
import SquidraDomain
import SquidraPostgres
import SquidraWorld
import XCTest

// SAFETY: stateless suite; mutable persistence is confined to an isolated database.
final class WorldChangesSQLTests: XCTestCase, @unchecked Sendable {
    private static func instant(_ value: Int64) throws -> UTCInstant { try UTCInstant(secondsSince1970:Double(value)/1_000_000) }
    func testRealBoundariesFiltersEvidenceAndStablePagesAcrossLateProjection() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["SQUIDRA_TEST_DB_PORT"],let port = Int(text),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            XCTFail("Run through the isolated SQD-015 database helper");return
        }
        let client = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
        let actor = UUID(),subject = UUID(),otherSubject = UUID(),a = UUID(),b = UUID(),c = UUID(),d = UUID(),frame = UUID(),stream = UUID(),otherStream = UUID()
        let journal = PostgresWorldRepository(client:client),projection = PostgresLocationProjection(actorID:actor,client:client)
        let t0: Int64 = 1_700_000_000_000_000,t1 = t0+100_000_000,t2 = t0+200_000_000,t3 = t0+300_000_000
        @Sendable func append(_ change: LocationFactChange, expected: Int64, key: String, extra: [UUID] = [], owner: UUID? = nil, streamID: UUID? = nil) async throws -> JournalEvent {
            let event = try WorldEventDraft(actorID:owner ?? actor,streamID:streamID ?? stream,entityIDs:[change.subjectID,change.locationID]+extra,type:change.eventType,
                times:JournalTimes(occurredAt:nil,observedAt:Self.instant(t0),timeZone:IANATimeZone(identifier:"Europe/Paris")),sourceID:"fixture:changes",
                confidence:Confidence(change.basis == .inferred ? 0.5 : 0.9),payloadVersion:1,payload:change.encodedPayload(),causationID:change.correctsEventID,correlationID:UUID())
            return try await journal.append(event,expectedVersion:expected,idempotencyKey:key,deadline:.now.advanced(by:.seconds(4))).event
        }
        @Sendable func query(_ start: Int64, _ end: Int64, known: Int64, entity: UUID? = nil, location: UUID? = nil) throws -> WorldChangesQuery {
            try WorldChangesQuery(actorID:actor,from:Self.instant(start),to:Self.instant(end),knownAt:Self.instant(known),subjectID:entity,locationID:location)
        }
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            for entity in [subject,otherSubject,a,b,c,d] { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect() }
            _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(frame),\(actor),'changes',3,'metres')").collect()
            let first = try await append(LocationFactChange(subjectID:subject,locationID:a,frameID:frame,valid:FactInterval(fromMicroseconds:t0,toMicroseconds:t1),basis:.observed),expected:0,key:"first")
            let second = try await append(LocationFactChange(subjectID:subject,locationID:b,frameID:frame,valid:FactInterval(fromMicroseconds:t1,toMicroseconds:t2),basis:.observed),expected:1,key:"second")
            let third = try await append(LocationFactChange(subjectID:subject,locationID:c,frameID:frame,valid:FactInterval(fromMicroseconds:t2,toMicroseconds:nil),basis:.observed),expected:2,key:"third")
            let tied = try await append(LocationFactChange(subjectID:otherSubject,locationID:a,frameID:frame,valid:FactInterval(fromMicroseconds:t1,toMicroseconds:nil),basis:.observed),expected:0,key:"tied",streamID:otherStream)
            for event in [first,second,third,tied] { try await projection.apply(event) }
            let correction = try await append(LocationFactChange(subjectID:subject,locationID:d,frameID:frame,valid:FactInterval(fromMicroseconds:t1,toMicroseconds:t2),basis:.observed,correctsEventID:second.draft.id),expected:3,key:"correction",extra:[b])
            // The correction is already recorded before knownAt, but remains
            // unapplied when page one captures its projected high-water mark.
            let all = try query(t0,t3,known:correction.recordedMicroseconds)
            let firstPage = try await projection.changes(all,limit:1,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(firstPage.changes.map(\.id),[first.draft.id]);XCTAssertTrue(firstPage.projectionBehind)
            let originalCursor = try XCTUnwrap(firstPage.next)
            try await projection.apply(correction)
            let outside = try await append(LocationFactChange(subjectID:otherSubject,locationID:b,frameID:frame,valid:FactInterval(fromMicroseconds:t3,toMicroseconds:nil),basis:.observed),expected:1,key:"outside-end",streamID:otherStream)
            try await projection.apply(outside)
            var seen = firstPage.changes,next = firstPage.next
            while let cursor = next {
                let page = try await projection.changes(all,cursor:cursor,limit:1,deadline:.now.advanced(by:.seconds(4)))
                XCTAssertEqual(page.throughSequence,firstPage.throughSequence);XCTAssertEqual(page.availableThroughSequence,firstPage.availableThroughSequence)
                seen += page.changes;next = page.next
            }
            XCTAssertEqual(seen.count,4);XCTAssertEqual(Set(seen.map(\.id)),[first.draft.id,second.draft.id,third.draft.id,tied.draft.id])
            XCTAssertEqual(Set(seen.map(\.id)).count,seen.count)
            let originalSecond = try XCTUnwrap(seen.first(where:{$0.id == second.draft.id})),originalThird = try XCTUnwrap(seen.first(where:{$0.id == third.draft.id}))
            XCTAssertEqual(originalSecond.current.locationID,b);XCTAssertNil(originalSecond.current.transaction.toMicroseconds)
            XCTAssertEqual(originalThird.previous.map(\.locationID),[b])
            let fresh = try await projection.changes(all,limit:128,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertFalse(fresh.projectionBehind);XCTAssertEqual(Set(fresh.changes.map(\.id)),[first.draft.id,correction.draft.id,third.draft.id,tied.draft.id])
            let corrected = try XCTUnwrap(fresh.changes.first(where:{$0.id == correction.draft.id}))
            XCTAssertEqual(corrected.kind,.correction);XCTAssertEqual(corrected.previous.map(\.locationID),[b])
            XCTAssertEqual(Set(corrected.supportingEventIDs),[second.draft.id,correction.draft.id])
            let currentThird = try XCTUnwrap(fresh.changes.first(where:{$0.id == third.draft.id}))
            XCTAssertEqual(currentThird.previous.map(\.locationID),[d])
            let exact = try await projection.changes(query(t1,t2,known:correction.recordedMicroseconds,entity:subject),deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(exact.changes.map(\.id),[correction.draft.id])
            let destination = try await projection.changes(query(t2,t3,known:correction.recordedMicroseconds,entity:subject,location:c),deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(destination.changes.map(\.id),[third.draft.id])
            let origin = try await projection.changes(query(t1,t2,known:tied.recordedMicroseconds,entity:subject,location:a),deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(origin.changes.map(\.id),[second.draft.id]);XCTAssertEqual(origin.changes.first?.kind,.locationChanged)
            let replaced = try await projection.changes(query(t1,t2,known:correction.recordedMicroseconds,entity:subject,location:b),deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(replaced.changes.map(\.id),[correction.draft.id])
            let missing = try await projection.changes(query(t0,t1,known:correction.recordedMicroseconds,location:d),deadline:.now.advanced(by:.seconds(4)))
            XCTAssertTrue(missing.changes.isEmpty);XCTAssertNil(missing.next)
            let initialOther = try await projection.changes(query(t1,t2,known:correction.recordedMicroseconds,entity:otherSubject),deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(initialOther.changes.map(\.id),[tied.draft.id]);XCTAssertEqual(initialOther.changes.first?.kind,.observation)
            XCTAssertTrue(initialOther.changes.first?.uncertainty.contains(.priorStateUnknown) == true)
            do { _ = try await projection.changes(query(t0,t3,known:correction.recordedMicroseconds,entity:subject),cursor:originalCursor,deadline:.now.advanced(by:.seconds(4)));XCTFail("Changed filters reused cursor") }
            catch { XCTAssertEqual(error as? WorldChangesError,.invalidCursor) }
            let future = try WorldChangesCursor(query:all,throughSequence:outside.sequence+100,availableThroughSequence:outside.sequence+100,afterValidMicroseconds:t0,afterFactID:first.draft.id)
            do { _ = try await projection.changes(all,cursor:future,deadline:.now.advanced(by:.seconds(4)));XCTFail("Future watermark accepted") }
            catch { XCTAssertEqual(error as? WorldChangesError,.invalidCursor) }
            do { _ = try await projection.changes(query(t0,t3,known:correction.recordedMicroseconds,location:UUID()),deadline:.now.advanced(by:.seconds(4)));XCTFail("Foreign/unknown place accepted") }
            catch { XCTAssertEqual(error as? WorldChangesError,.notFound) }
            let foreign = try WorldChangesQuery(actorID:UUID(),from:Self.instant(t0),to:Self.instant(t3),knownAt:Self.instant(correction.recordedMicroseconds))
            do { _ = try await projection.changes(foreign,deadline:.now.advanced(by:.seconds(4)));XCTFail("Wrong actor queried") }
            catch { XCTAssertEqual(error as? WorldChangesError,.notFound) }
            let inferred = try await append(LocationFactChange(subjectID:subject,locationID:d,frameID:frame,valid:FactInterval(fromMicroseconds:t2,toMicroseconds:nil),basis:.inferred),expected:4,key:"inferred")
            try await projection.apply(inferred)
            let ambiguous = try await projection.changes(query(t2,t3,known:inferred.recordedMicroseconds,entity:subject),deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(ambiguous.changes.count,2)
            XCTAssertTrue(ambiguous.changes.allSatisfy({$0.kind == .observation && $0.uncertainty.contains(.conflictingLocations)}))
            XCTAssertTrue(ambiguous.changes.contains(where:{$0.uncertainty.contains(.inferredEvidence)}))
            for change in ambiguous.changes { XCTAssertTrue(change.supportingEventIDs.contains(change.current.sourceEventID));XCTAssertFalse(change.previous.isEmpty) }
            let repeatedOldPage = try await projection.changes(all,cursor:originalCursor,limit:128,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(Set(repeatedOldPage.changes.map(\.id)),[second.draft.id,third.draft.id,tied.draft.id])
            // Supporting evidence is bounded too: do not silently omit the 129th
            // agreeing predecessor when describing one new location state.
            let limitActor = UUID(),limitSubject = UUID(),limitA = UUID(),limitB = UUID(),limitFrame = UUID(),limitStream = UUID()
            for entity in [limitSubject,limitA,limitB] { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(limitActor),'fixture')").collect() }
            _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(limitFrame),\(limitActor),'support-limit',3,'metres')").collect()
            let limited = PostgresLocationProjection(actorID:limitActor,client:client)
            let prior = try LocationFactChange(subjectID:limitSubject,locationID:limitA,frameID:limitFrame,valid:FactInterval(fromMicroseconds:t0,toMicroseconds:t1),basis:.observed)
            for index in 0..<129 {
                let event = try await append(prior,expected:Int64(index),key:"prior-\(index)",owner:limitActor,streamID:limitStream)
                try await limited.apply(event)
            }
            let new = try await append(LocationFactChange(subjectID:limitSubject,locationID:limitB,frameID:limitFrame,valid:FactInterval(fromMicroseconds:t1,toMicroseconds:t2),basis:.observed),expected:129,key:"new",owner:limitActor,streamID:limitStream)
            try await limited.apply(new)
            let bounded = try WorldChangesQuery(actorID:limitActor,from:Self.instant(t1),to:Self.instant(t2),knownAt:Self.instant(new.recordedMicroseconds))
            do { _ = try await limited.changes(bounded,limit:1,deadline:.now.advanced(by:.seconds(4)));XCTFail("Supporting evidence truncated") }
            catch { XCTAssertEqual(error as? WorldChangesError,.resultLimitExceeded) }
        }
    }
}
