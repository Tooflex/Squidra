import Foundation
import PostgresNIO
import SquidraDomain
import SquidraPostgres
import SquidraWorld
import XCTest

// SAFETY: stateless suite; every mutable row belongs to the isolated SQL helper.
final class WorldRecoverySQLTests: XCTestCase, @unchecked Sendable {
    private static func instant(_ micros: Int64) throws -> UTCInstant { try UTCInstant(secondsSince1970:Double(micros)/1_000_000) }
    func testRealCheckpointResumeEmptyCacheRebuildAndBoundedFailure() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["SQUIDRA_TEST_DB_PORT"], let port = Int(text), let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            XCTFail("Run through the isolated SQD-025-RECOVERY helper"); return
        }
        let client = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
        let actor = UUID(), foreign = UUID(), subject = UUID(), a = UUID(), b = UUID(), d = UUID(), frame = UUID(), stream = UUID()
        let repository = PostgresWorldRepository(client:client), projection = PostgresLocationProjection(actorID:actor,client:client)
        let t0: Int64 = 1_700_000_000_000_000, t1 = t0+100_123_457
        @Sendable func append(_ change: LocationFactChange, version: Int64, extra: [UUID] = []) async throws -> JournalEvent {
            let draft = try WorldEventDraft(actorID:actor,streamID:stream,entityIDs:[subject,change.locationID]+extra,type:change.eventType,
                times:JournalTimes(occurredAt:nil,observedAt:Self.instant(t0),timeZone:IANATimeZone(identifier:"Europe/Paris")),
                sourceID:"fixture:world-recovery",confidence:Confidence(0.85),payloadVersion:1,payload:change.encodedPayload(),causationID:change.correctsEventID,correlationID:UUID())
            return try await repository.append(draft,expectedVersion:version,idempotencyKey:"recover-\(version)",deadline:.now.advanced(by:.seconds(4))).event
        }
        @Sendable func clearOwnedCache() async throws {
            _ = try await client.query("DELETE FROM spatial_facts WHERE actor_id=\(actor) AND predicate='located_at'").collect()
            _ = try await client.query("DELETE FROM projection_versions WHERE actor_id=\(actor) AND projection_name='world.locations'").collect()
        }
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() }; defer { group.cancelAll() }
            for entity in [subject,a,b,d] { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect() }
            _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(frame),\(actor),'recovery',3,'metres')").collect()
            let first = try await append(LocationFactChange(subjectID:subject,locationID:a,frameID:frame,valid:FactInterval(fromMicroseconds:t0,toMicroseconds:t1),basis:.observed),version:0)
            let second = try await append(LocationFactChange(subjectID:subject,locationID:b,frameID:frame,valid:FactInterval(fromMicroseconds:t1,toMicroseconds:nil),basis:.observed),version:1)
            let correction = try await append(LocationFactChange(subjectID:subject,locationID:d,frameID:frame,valid:FactInterval(fromMicroseconds:t0,toMicroseconds:t1),basis:.observed,correctsEventID:first.draft.id),version:2,extra:[a])
            try await projection.apply(first)
            let recovery = WorldProjectionRecovery(actorID:actor,repository:repository,projector:projection,limits:try WorldRecoveryLimits(pageSize:1))
            let tail = try await recovery.recover()
            XCTAssertEqual(tail.startSequence,first.sequence); XCTAssertEqual(tail.capturedThroughSequence,correction.sequence); XCTAssertEqual(tail.replayedEvents,2)
            let current = try await projection.state(actorID:actor,subjectID:subject,validAt:Self.instant(t0+1_000_000),knownAt:correction.recordedAt,deadline:.now.advanced(by:.seconds(4)))
            let historical = try await projection.state(actorID:actor,subjectID:subject,validAt:Self.instant(t0+1_000_000),knownAt:second.recordedAt,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(current.facts.map(\.locationID),[d]); XCTAssertEqual(historical.facts.map(\.locationID),[a])
            let again = try await recovery.recover(); XCTAssertEqual(again.replayedEvents,0)
            try await clearOwnedCache()
            let freshProjection = PostgresLocationProjection(actorID:actor,client:client)
            let rebuilt = try await WorldProjectionRecovery(actorID:actor,repository:repository,projector:freshProjection).recover()
            XCTAssertEqual(rebuilt.startSequence,0); XCTAssertEqual(rebuilt.replayedEvents,3)
            let restored = try await freshProjection.state(actorID:actor,subjectID:subject,validAt:Self.instant(t0+1_000_000),knownAt:correction.recordedAt,deadline:.now.advanced(by:.seconds(4)))
            let restoredHistory = try await freshProjection.state(actorID:actor,subjectID:subject,validAt:Self.instant(t0+1_000_000),knownAt:second.recordedAt,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(restored.facts,current.facts); XCTAssertEqual(restoredHistory.facts,historical.facts)
            XCTAssertEqual(restored.facts.first?.sourceEventID,correction.draft.id)
            XCTAssertEqual(restored.facts.first?.confidence.value,0.85)
            XCTAssertEqual(restored.facts.first?.timestamps.timeZone.identifier,"Europe/Paris")
            let other = PostgresLocationProjection(actorID:foreign,client:client)
            let foreignReport = try await WorldProjectionRecovery(actorID:foreign,repository:repository,projector:other).recover()
            XCTAssertEqual(foreignReport.capturedThroughSequence,0); XCTAssertEqual(foreignReport.replayedEvents,0)
            do { _ = try await WorldProjectionRecovery(actorID:actor,repository:repository,projector:other).recover(); XCTFail("Misbound actor projection accepted") }
            catch { XCTAssertEqual(error as? WorldRecoveryError,.unavailable) }
            let otherCheckpoint = try await other.checkpoint(); XCTAssertNil(otherCheckpoint.lastSequence)
            try await clearOwnedCache()
            do { _ = try await WorldProjectionRecovery(actorID:actor,repository:repository,projector:projection,limits:WorldRecoveryLimits(pageSize:1,maximumEvents:1)).recover(); XCTFail("Recovery event limit ignored") }
            catch { XCTAssertEqual(error as? WorldRecoveryError,.eventLimit) }
            let prefix = try await projection.checkpoint(); XCTAssertEqual(prefix.lastSequence,first.sequence)
            let partial = try await projection.state(actorID:actor,subjectID:subject,validAt:Self.instant(t0+1_000_000),knownAt:correction.recordedAt,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertTrue(partial.uncertainty.contains(.projectionBehind))
            let resumed = try await recovery.recover(); XCTAssertEqual(resumed.startSequence,first.sequence); XCTAssertEqual(resumed.replayedEvents,2)
            // A missing checkpoint with orphaned fact rows is an invalid cache,
            // not permission to overwrite data or fabricate a completed replay.
            _ = try await client.query("DELETE FROM projection_versions WHERE actor_id=\(actor) AND projection_name='world.locations'").collect()
            do { _ = try await recovery.recover(); XCTFail("Orphaned cache accepted") }
            catch { XCTAssertEqual(error as? WorldRecoveryError,.unavailable) }
            try await clearOwnedCache()
            _ = try await recovery.recover()
            let source = try await repository.page(actorID:actor,afterSequence:0,cursor:nil,limit:128,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(source.events.map(\.draft.id),[first.draft.id,second.draft.id,correction.draft.id])
            XCTAssertEqual(source.events.map(\.recordedMicroseconds),[first.recordedMicroseconds,second.recordedMicroseconds,correction.recordedMicroseconds])
        }
    }
}
