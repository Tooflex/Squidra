import Foundation
import PostgresNIO
import SquidraDomain
import SquidraPostgres
import SquidraWorld
import XCTest

// SAFETY: stateless suite; all mutable state lives in an isolated PostgreSQL fixture.
final class WorldProjectionSQLTests: XCTestCase, @unchecked Sendable {
    private static func instant(_ value: Int64) throws -> UTCInstant { try UTCInstant(secondsSince1970:Double(value)/1_000_000) }
    func testRealThreeMovementsLateCorrectionKnowledgeTimesAndAtomicProjection() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["SQUIDRA_TEST_DB_PORT"],let port = Int(text),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            XCTFail("Run through the isolated SQD-014 database helper");return
        }
        let client = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
        let actor = UUID(),subject = UUID(),a = UUID(),b = UUID(),c = UUID(),d = UUID(),spare = UUID(),frame = UUID(),stream = UUID()
        let journal = PostgresWorldRepository(client:client),projection = PostgresLocationProjection(actorID:actor,client:client)
        let t0: Int64 = 1_700_000_000_000_000,t1: Int64 = 1_700_000_100_000_000,t2: Int64 = 1_700_000_200_000_000
        @Sendable func draft(_ change: LocationFactChange, extraEntities: [UUID] = [], owner: UUID? = nil, streamID: UUID? = nil,
                             confidence: Double = 0.9, source: String = "fixture:camera") throws -> WorldEventDraft {
            try WorldEventDraft(actorID:owner ?? actor,streamID:streamID ?? stream,entityIDs:[change.subjectID,change.locationID]+extraEntities,type:change.eventType,
                times:JournalTimes(occurredAt:nil,observedAt:Self.instant(t0+10),timeZone:IANATimeZone(identifier:"Europe/Paris")),
                sourceID:source,confidence:Confidence(confidence),payloadVersion:1,payload:change.encodedPayload(),causationID:change.correctsEventID,correlationID:UUID())
        }
        @Sendable func state(_ valid: Int64, _ known: Int64, entity: UUID? = nil) async throws -> WorldStateSnapshot {
            try await projection.state(actorID:actor,subjectID:entity ?? subject,validAt:Self.instant(valid),knownAt:Self.instant(known),deadline:.now.advanced(by:.seconds(4)))
        }
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            for entity in [subject,a,b,c,d,spare] { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect() }
            _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(frame),\(actor),'fixture',3,'metres')").collect()
            let changes = try [LocationFactChange(subjectID:subject,locationID:a,frameID:frame,valid:FactInterval(fromMicroseconds:t0,toMicroseconds:t1),basis:.observed),
                LocationFactChange(subjectID:subject,locationID:b,frameID:frame,valid:FactInterval(fromMicroseconds:t1,toMicroseconds:t2),basis:.observed),
                LocationFactChange(subjectID:subject,locationID:c,frameID:frame,valid:FactInterval(fromMicroseconds:t2,toMicroseconds:nil),basis:.observed)]
            var events: [JournalEvent] = []
            for (index,change) in changes.enumerated() {
                let append = try await journal.append(draft(change,confidence:index == 2 ? 0.7 : 0.9),expectedVersion:Int64(index),idempotencyKey:"movement-\(index)",deadline:.now.advanced(by:.seconds(4)))
                events.append(append.event)
            }
            let thirdTime = events[2].recordedMicroseconds
            do { try await projection.apply(events[1]);XCTFail("Projection skipped earlier journal event") }
            catch { XCTAssertEqual(error as? WorldProjectionError,.outOfOrder) }
            let behind = try await state(t0+1,thirdTime)
            XCTAssertTrue(behind.facts.isEmpty);XCTAssertTrue(behind.uncertainty.contains(.projectionBehind))
            // The caller's payload is not authoritative; only its persisted ID is.
            let original = events[0].draft
            let forged = try WorldEventDraft(id:original.id,actorID:actor,streamID:original.streamID,entityIDs:original.entityIDs,type:original.type,
                times:original.times,sourceID:"fixture:forged",confidence:Confidence(1),payloadVersion:1,payload:Data(#"{"instruction":"forge location"}"#.utf8),correlationID:UUID())
            try await projection.apply(JournalEvent(sequence:events[0].sequence,streamVersion:events[0].streamVersion,draft:forged,recordedMicroseconds:events[0].recordedMicroseconds))
            try await projection.apply(events[1]);try await projection.apply(events[2])
            for (time,location) in [(t0,a),(t1,b),(t2,c)] {
                let result = try await state(time,thirdTime)
                XCTAssertEqual(result.facts.map(\.locationID),[location]);XCTAssertFalse(result.uncertainty.contains(.projectionBehind))
                XCTAssertEqual(result.facts.first?.sourceID,"fixture:camera")
                XCTAssertEqual(result.facts.first?.timestamps.timeZone.identifier,"Europe/Paris")
                XCTAssertNil(result.facts.first?.timestamps.occurredAt)
            }
            _ = try await client.query("UPDATE spatial_facts SET confidence=1 WHERE actor_id=\(actor) AND id=\(events[0].draft.id)").collect()
            do { _ = try await state(t0,thirdTime);XCTFail("Materialized confidence exceeded its immutable source") }
            catch { XCTAssertEqual(error as? WorldProjectionError,.corruptRecord) }
            _ = try await client.query("UPDATE spatial_facts SET confidence=0.9 WHERE actor_id=\(actor) AND id=\(events[0].draft.id)").collect()
            let prior = try await state(t0-1,thirdTime),notYetKnown = try await state(t0,events[0].recordedMicroseconds-1)
            XCTAssertEqual(prior.uncertainty,[.noEvidence]);XCTAssertTrue(notYetKnown.facts.isEmpty)
            let emptyEntity = try await state(t0,thirdTime,entity:spare);XCTAssertEqual(emptyEntity.uncertainty,[.noEvidence])
            let correction = LocationFactChange(subjectID:subject,locationID:d,frameID:frame,valid:changes[1].valid,basis:.observed,correctsEventID:events[1].draft.id)
            let appended = try await journal.append(draft(correction,extraEntities:[b],confidence:0.95,source:"fixture:late-correction"),expectedVersion:3,idempotencyKey:"late-correction",deadline:.now.advanced(by:.seconds(4)))
            let before = try await projection.checkpoint()
            _ = try await client.query("""
                CREATE FUNCTION fixture_reject_checkpoint() RETURNS trigger LANGUAGE plpgsql AS $body$
                BEGIN RAISE EXCEPTION 'fixture checkpoint write failure' USING ERRCODE='23514'; RETURN NEW; END $body$
                """).collect()
            _ = try await client.query("CREATE TRIGGER fixture_reject_checkpoint BEFORE UPDATE ON projection_versions FOR EACH ROW EXECUTE FUNCTION fixture_reject_checkpoint()").collect()
            do { try await projection.apply(appended.event);XCTFail("Checkpoint failure ignored") }
            catch { XCTAssertEqual(error as? WorldProjectionError,.invalidFact) }
            _ = try await client.query("DROP TRIGGER fixture_reject_checkpoint ON projection_versions").collect()
            _ = try await client.query("DROP FUNCTION fixture_reject_checkpoint()").collect()
            let afterFailure = try await projection.checkpoint()
            XCTAssertEqual(before.state.bytes,afterFailure.state.bytes)
            let rolledBack = try await state(t1,appended.event.recordedMicroseconds)
            XCTAssertEqual(rolledBack.facts.map(\.locationID),[b]);XCTAssertTrue(rolledBack.uncertainty.contains(.projectionBehind))
            try await projection.apply(appended.event)
            let reloaded = PostgresLocationProjection(actorID:actor,client:client)
            let stable = try await reloaded.checkpoint();try await reloaded.apply(appended.event)
            let replay = try await reloaded.checkpoint();XCTAssertEqual(stable.state.bytes,replay.state.bytes)
            let oldKnowledge = try await state(t1,thirdTime),newKnowledge = try await state(t1,appended.event.recordedMicroseconds)
            XCTAssertEqual(oldKnowledge.facts.map(\.locationID),[b]);XCTAssertEqual(newKnowledge.facts.map(\.locationID),[d])
            XCTAssertEqual(oldKnowledge.facts.first?.sourceEventID,events[1].draft.id)
            XCTAssertEqual(newKnowledge.facts.first?.sourceEventID,appended.event.draft.id)
            XCTAssertEqual(newKnowledge.facts.first?.sourceID,"fixture:late-correction")
            XCTAssertEqual(newKnowledge.facts.first?.confidence.value,0.95)
            XCTAssertEqual(oldKnowledge.facts.first?.transaction.toMicroseconds,appended.event.recordedMicroseconds)
            XCTAssertEqual(newKnowledge.facts.first?.transaction.fromMicroseconds,appended.event.recordedMicroseconds)
            let atEnd = try await state(t2,appended.event.recordedMicroseconds)
            XCTAssertEqual(atEnd.facts.map(\.locationID),[c])
            let inferred = LocationFactChange(subjectID:subject,locationID:d,frameID:frame,valid:changes[2].valid,basis:.inferred)
            let competing = try await journal.append(draft(inferred,confidence:0.55,source:"fixture:inferred"),expectedVersion:4,idempotencyKey:"contradictory",deadline:.now.advanced(by:.seconds(4)))
            try await projection.apply(competing.event)
            let contradiction = try await state(t2,competing.event.recordedMicroseconds)
            XCTAssertEqual(Set(contradiction.facts.map(\.locationID)),[c,d])
            XCTAssertEqual(contradiction.uncertainty,[.conflictingLocations,.inferredEvidence])
            XCTAssertEqual(Set(contradiction.facts.map(\.sourceEventID)),[events[2].draft.id,competing.event.draft.id])
            do { _ = try await projection.state(actorID:UUID(),subjectID:subject,validAt:Self.instant(t0),knownAt:Self.instant(thirdTime),deadline:.now.advanced(by:.seconds(4)));XCTFail("Wrong actor queried") }
            catch { XCTAssertEqual(error as? WorldProjectionError,.notFound) }
            let otherActor = UUID(),otherFrame = UUID()
            _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(otherFrame),\(otherActor),'foreign',3,'metres')").collect()
            let badFrame = LocationFactChange(subjectID:subject,locationID:a,frameID:otherFrame,valid:changes[0].valid,basis:.observed)
            let foreign = try await journal.append(draft(badFrame),expectedVersion:5,idempotencyKey:"foreign-frame",deadline:.now.advanced(by:.seconds(4)))
            let checkpoint = try await projection.checkpoint()
            do { try await projection.apply(foreign.event);XCTFail("Foreign frame projected") }
            catch { XCTAssertEqual(error as? WorldProjectionError,.notFound) }
            let preserved = try await projection.checkpoint();XCTAssertEqual(checkpoint.state.bytes,preserved.state.bytes)
            // Simulate a backwards recording clock in a fresh actor. The raw
            // fixture is deliberate; journal mutation remains forbidden.
            let skewActor = UUID(),skewSubject = UUID(),skewPlace = UUID(),skewFrame = UUID(),skewStream = UUID()
            for entity in [skewSubject,skewPlace] { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(skewActor),'fixture')").collect() }
            _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(skewFrame),\(skewActor),'clock',3,'metres')").collect()
            let skewProjection = PostgresLocationProjection(actorID:skewActor,client:client)
            let originalChange = try LocationFactChange(subjectID:skewSubject,locationID:skewPlace,frameID:skewFrame,valid:FactInterval(fromMicroseconds:t0,toMicroseconds:nil),basis:.observed)
            let originalAppend = try await journal.append(draft(originalChange,owner:skewActor,streamID:skewStream),expectedVersion:0,idempotencyKey:"clock-original",deadline:.now.advanced(by:.seconds(4)))
            try await skewProjection.apply(originalAppend.event)
            let backwards = originalAppend.event.recordedMicroseconds-1,skewID = UUID()
            let replacement = LocationFactChange(subjectID:skewSubject,locationID:skewPlace,frameID:skewFrame,valid:originalChange.valid,basis:.observed,correctsEventID:originalAppend.event.draft.id)
            let payload = String(decoding:try replacement.encodedPayload(),as:UTF8.self)
            _ = try await client.query("""
                INSERT INTO world_events(event_id,actor_id,stream_id,stream_version,idempotency_key,entity_ids,event_type,observed_at,recorded_at,source_id,confidence,payload_version,payload,causation_id,correlation_id)
                VALUES(\(skewID),\(skewActor),\(skewStream),2,'clock-correction',\([skewSubject,skewPlace]),'world.location_corrected',to_timestamp(1700000000),
                    to_timestamp(\(Double(backwards/1_000_000)))+\(backwards%1_000_000)*interval '1 microsecond','fixture:clock',0.8,1,
                    jsonb_build_object('journalSchemaVersion','1','timeZone','Europe/Paris','data',\(payload)::jsonb),\(originalAppend.event.draft.id),\(UUID()))
                """).collect()
            let skewPage = try await journal.page(actorID:skewActor,deadline:.now.advanced(by:.seconds(4)))
            let skewEvent = try XCTUnwrap(skewPage.events.last),skewBefore = try await skewProjection.checkpoint()
            do { try await skewProjection.apply(skewEvent);XCTFail("Recording clock invented a positive transaction interval") }
            catch { XCTAssertEqual(error as? WorldProjectionError,.nonMonotonicKnowledgeTime) }
            let skewAfter = try await skewProjection.checkpoint();XCTAssertEqual(skewBefore.state.bytes,skewAfter.state.bytes)
            // Qualify completeness: 129 legitimate source observations must fail
            // the bounded query instead of hiding the last supporting event.
            let limitActor = UUID(),limitSubject = UUID(),limitPlace = UUID(),limitFrame = UUID(),limitStream = UUID()
            for entity in [limitSubject,limitPlace] { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(limitActor),'fixture')").collect() }
            _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(limitFrame),\(limitActor),'limit',3,'metres')").collect()
            let limited = PostgresLocationProjection(actorID:limitActor,client:client)
            let value = try LocationFactChange(subjectID:limitSubject,locationID:limitPlace,frameID:limitFrame,valid:FactInterval(fromMicroseconds:t0,toMicroseconds:nil),basis:.observed)
            var lastKnown: Int64 = 0
            for index in 0..<129 {
                let append = try await journal.append(draft(value,owner:limitActor,streamID:limitStream),expectedVersion:Int64(index),idempotencyKey:"limit-\(index)",deadline:.now.advanced(by:.seconds(4)))
                try await limited.apply(append.event);lastKnown = append.event.recordedMicroseconds
            }
            do { _ = try await limited.state(actorID:limitActor,subjectID:limitSubject,validAt:Self.instant(t0),knownAt:Self.instant(lastKnown),deadline:.now.advanced(by:.seconds(4)));XCTFail("Partial evidence silently returned") }
            catch { XCTAssertEqual(error as? WorldProjectionError,.resultLimitExceeded) }
        }
    }
}
