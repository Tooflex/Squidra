import Foundation
import PostgresNIO
import SquidraDomain
import SquidraMemory
import SquidraPerception
import SquidraSpatial
import SquidraPostgres
import SquidraWorld
import XCTest

final class WatchSQLTests: XCTestCase, @unchecked Sendable {
    static func report(actor: UUID, entity: UUID, unknownFinalConfidence: Bool = false) throws -> MovementReport {
        let frame = try SpatialCoordinateFrame(actorID: actor,id: UUID(),up: .positiveZ,calibration: SpatialCalibration(id: UUID(),version: "fixture-1",maximumErrorMeters: 0))
        let camera = UUID()
        let samples = try [0.0,0.2,0.2,0.2,0.5,0.5,0.5].enumerated().map { i,x in
            let time = try UTCInstant(secondsSince1970: 1_700_000_000+Double(i))
            let source = try SpatialSource(observationID: UUID(),cameraID: camera,imageFrameID: UUID(),modelID: "authored-scene",modelVersion: "1",
                times: ObservationTimestamps(occurredAt: nil,observedAt: time,recordedAt: time,timeZone: IANATimeZone(identifier: "Europe/Paris")),
                confidence: unknownFinalConfidence && i == 6 ? nil : Confidence(0.8))
            return try MovementSample(observedAt: time,observation: SpatialObservation(actorID: actor,entityID: entity,coordinateFrameID: frame.id,
                geometry: .calibrated3D(SpatialBox3D(lower: [x,0,0],upper: [x+0.1,0.1,0.1],maximumErrorMeters: 0)),association: .confirmed,
                validity: SpatialValidity(from: time,to: nil),source: source),frame: frame)
        }
        return try ConfirmedMovementDetector(actorID: actor,entityID: entity,epochID: UUID(),entityType: "cup",
            policy: MovementPolicy(id: UUID(),thresholdsByType: ["cup": MovementThreshold(minimumDisplacementMeters: 0.1)])).evaluate(samples)
    }
    func testDurableWatchAtomicNotificationReplayCancellationAndUntrustedEvents() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { XCTFail("Use SQD-026-SQL");return }
        let config = try LocalDatabaseConfiguration(port: port,username: "squidra",password: password,database: "squidra")
        let client = config.makeClient(),second = config.makeClient(),actor = UUID(),entity = UUID()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() };group.addTask { await second.run() };defer { group.cancelAll() }
            _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect()
            let store = PostgresIntentionStore(actorID: actor,client: client),reload = PostgresIntentionStore(actorID: actor,client: second)
            let journal = PostgresWorldRepository(client: client)
            let input = try Self.report(actor: actor,entity: entity),movement = input.events[0]
            let epoch = try MovementEpoch(detector: ConfirmedMovementDetector(actorID: actor,entityID: entity,epochID: movement.epochID,entityType: movement.entityType,policy: movement.policy),samples: input.samples,origin: .synthetic)
            let watch = try await store.watch(entityID: entity,key: "watch-1",deadline: .now.advanced(by: .seconds(4)))
            let repeated = try await reload.watch(entityID: entity,key: "watch-1",deadline: .now.advanced(by: .seconds(4)))
            XCTAssertEqual(watch,repeated)
            do { _ = try await reload.watch(entityID: UUID(),key: "watch-1",deadline: .now.advanced(by: .seconds(4)));XCTFail("Key changed entity") }
            catch { XCTAssertEqual(error as? WatchError,.conflict) }
            let ids = try await MovementEpochRecovery(store: PostgresMovementEpochStore(client: client,actorID: actor),publisher: MovementPublisher(actorID: actor,repository: journal)).submit(epoch,deadline: .now.advanced(by: .seconds(4)))
            // Roll back an injected failure after journal append but before the
            // delivery row and fulfilled state can commit.
            _ = try await client.query("CREATE FUNCTION reject_watch_delivery() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture rejected delivery'; END $$").collect()
            _ = try await client.query("CREATE TRIGGER reject_watch_delivery BEFORE INSERT ON watch_notifications FOR EACH ROW EXECUTE FUNCTION reject_watch_delivery()").collect()
            do { _ = try await store.deliver(intentionID: watch.id,eventID: ids[0],deadline: .now.advanced(by: .seconds(4)));XCTFail("Injected failure ignored") }
            catch { XCTAssertEqual(error as? WatchError,.unavailable) }
            _ = try await client.query("DROP TRIGGER reject_watch_delivery ON watch_notifications").collect()
            _ = try await client.query("DROP FUNCTION reject_watch_delivery()").collect()
            let active = try await reload.load(id: watch.id,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertEqual(active?.status,.active)
            let before = try await journal.page(actorID: actor,afterSequence: 0,cursor: nil,limit: 20,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertFalse(before.events.contains { $0.draft.type == "memory.watch_notified" })
            async let a = store.deliver(intentionID: watch.id,eventID: ids[0],deadline: .now.advanced(by: .seconds(4)))
            async let b = reload.deliver(intentionID: watch.id,eventID: ids[0],deadline: .now.advanced(by: .seconds(4)))
            let results = try await [a,b].compactMap { $0 }
            XCTAssertEqual(results.count,2);XCTAssertEqual(results.filter(\.created).count,1)
            XCTAssertEqual(Set(results.map(\.notificationEventID)).count,1)
            let replay = try await PostgresIntentionStore(actorID: actor,client: second).deliver(intentionID: watch.id,eventID: ids[0],deadline: .now.advanced(by: .seconds(4)))
            XCTAssertEqual(replay?.created,false)
            let next = try await reload.deliver(intentionID: watch.id,eventID: ids[1],deadline: .now.advanced(by: .seconds(4)))
            XCTAssertNil(next,"One-shot watch completes on its first movement")
            let terminal = try await reload.load(id: watch.id,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertEqual(terminal?.status,.fulfilled)
            let later = try await reload.watch(entityID: entity,key: "later",deadline: .now.advanced(by: .seconds(4)))
            let old = try await reload.deliver(intentionID: later.id,eventID: ids[1],deadline: .now.advanced(by: .seconds(4)))
            XCTAssertNil(old,"Historical movement cannot trigger a new watch")
            let cancel = try await reload.cancel(id: later.id,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertEqual(cancel.status,.cancelled)
            let observer = try await store.watch(entityID: entity,key: "untrusted",deadline: .now.advanced(by: .seconds(4)))
            let known = before.events[0].draft
            let forged = try WorldEventDraft(actorID: actor,streamID: UUID(),entityIDs: [entity],type: "perception.movement_confirmed",times: known.times,sourceID: known.sourceID,confidence: known.confidence,payloadVersion: 1,payload: known.payload.bytes,correlationID: known.correlationID)
            let counterfeit = try await journal.append(forged,expectedVersion: 0,idempotencyKey: "counterfeit",deadline: .now.advanced(by: .seconds(4)))
            let ignored = try await store.deliver(intentionID: observer.id,eventID: counterfeit.event.draft.id,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertNil(ignored,"Matching type/payload without derived identity is not qualified evidence")
            let foreign = try await PostgresIntentionStore(actorID: UUID(),client: second).load(id: watch.id,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertNil(foreign)
            let page = try await journal.page(actorID: actor,afterSequence: 0,cursor: nil,limit: 20,deadline: .now.advanced(by: .seconds(4)))
            let notifications = page.events.filter { $0.draft.type == "memory.watch_notified" }
            XCTAssertEqual(notifications.count,1)
            XCTAssertEqual(notifications[0].draft.causationID,ids[0])
            let outbox = try await second.query("SELECT count(*) FROM outbox WHERE actor_id=\(actor)").collect()
            XCTAssertEqual(try outbox[0].decode(Int.self),0)
        }
    }
}
