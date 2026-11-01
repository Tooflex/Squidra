import Foundation
import PostgresNIO
import SquidraDomain
import SquidraSpatial
import SquidraPerception
@testable import SquidraPostgres
import SquidraWorld
import XCTest

private struct LostMovementAcknowledgement: WorldRepository {
    let base: any WorldRepository
    func append(_ event: WorldEventDraft, expectedVersion: Int64, idempotencyKey: String, deadline: ContinuousClock.Instant) async throws -> JournalAppend {
        _ = try await base.append(event,expectedVersion: expectedVersion,idempotencyKey: idempotencyKey,deadline: deadline)
        throw WorldJournalError.unavailable
    }
    func page(actorID: UUID, afterSequence: Int64, cursor: JournalCursor?, limit: Int, deadline: ContinuousClock.Instant) async throws -> JournalPage {
        try await base.page(actorID: actorID,afterSequence: afterSequence,cursor: cursor,limit: limit,deadline: deadline)
    }
}
final class MovementPublicationSQLTests: XCTestCase, @unchecked Sendable {
    private static func report(actor: UUID, entity: UUID, unknownFinalConfidence: Bool = false) throws -> MovementReport {
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
    func testEpochCodecPreservesUnqualifiedEvidenceAndOcclusionsExactly() throws {
        let actor = UUID(),entity = UUID(),report = try Self.report(actor: actor,entity: entity,unknownFinalConfidence: true)
        let event = report.events[0],original = report.samples.last!.observation!
        let detector = try ConfirmedMovementDetector(actorID: actor,entityID: entity,epochID: event.epochID,entityType: event.entityType,policy: event.policy)
        for geometry in [SpatialGeometry.missingDepth,.uncalibrated2D,original.geometry] {
            let observation = SpatialObservation(actorID: actor,entityID: entity,coordinateFrameID: nil,geometry: geometry,
                association: .candidate,validity: original.validity,source: original.source)
            let samples = [MovementSample(observedAt: original.source.times.observedAt,observation: observation,frame: nil),
                MovementSample(observedAt: try UTCInstant(secondsSince1970: original.source.times.observedAt.secondsSince1970+1),observation: nil,frame: nil)]
            let epoch = try MovementEpoch(detector: detector,samples: samples,origin: .synthetic)
            let decoded = try MovementEpochCodec.decode(MovementEpochCodec.encode(epoch))
            XCTAssertEqual(decoded.samples,samples)
            XCTAssertTrue(try decoded.evaluate().events.isEmpty)
        }
    }
    func testDurableReplayLostAcknowledgementConcurrentPublicationAndProjectionIsolation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let value = env["SQUIDRA_TEST_DB_PORT"],let port = Int(value),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            XCTFail("Run with isolated T07-SQL helper");return
        }
        let config = try LocalDatabaseConfiguration(port: port,username: "squidra",password: password,database: "squidra")
        let first = config.makeClient(),second = config.makeClient(),actor = UUID(),entity = UUID()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await first.run() };group.addTask { await second.run() };defer { group.cancelAll() }
            _ = try await first.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect()
            let report = try Self.report(actor: actor,entity: entity)
            XCTAssertEqual(report.events.count,2)
            let event = report.events[0]
            let detector = try ConfirmedMovementDetector(actorID: actor,entityID: entity,epochID: event.epochID,entityType: event.entityType,policy: event.policy)
            let epoch = try MovementEpoch(detector: detector,samples: report.samples,origin: .synthetic)
            let epochs = PostgresMovementEpochStore(client: first,actorID: actor)
            try await epochs.save(epoch,deadline: .now.advanced(by: .seconds(4)))
            let reopenedEpochs = PostgresMovementEpochStore(client: second,actorID: actor)
            try await reopenedEpochs.save(epoch,deadline: .now.advanced(by: .seconds(4)))
            let loadedValue = try await reopenedEpochs.load(epochID: event.epochID,deadline: .now.advanced(by: .seconds(4)))
            let loaded = try XCTUnwrap(loadedValue)
            XCTAssertEqual(loaded.samples,epoch.samples)
            XCTAssertEqual(loaded.detector.policy,epoch.detector.policy)
            XCTAssertEqual(try loaded.evaluate().events.map(\.id),report.events.map(\.id))
            let changed = try MovementEpoch(detector: detector,samples: report.samples,origin: .sensor)
            do { try await reopenedEpochs.save(changed,deadline: .now.advanced(by: .seconds(4)));XCTFail("Epoch overwritten") }
            catch { XCTAssertEqual(error as? MovementEpochError,.conflict) }
            do { _ = try await second.query("DELETE FROM movement_epochs WHERE actor_id=\(actor)").collect();XCTFail("Immutable epoch deleted") }
            catch { /* Database trigger refuses mutation. */ }
            let foreignEpoch = try await PostgresMovementEpochStore(client: second,actorID: UUID()).load(epochID: event.epochID,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertNil(foreignEpoch)
            var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MovementEpochCodec.encode(epoch).utf8)) as? [String:Any])
            wire["unexpected"] = true
            XCTAssertThrowsError(try MovementEpochCodec.decode(String(decoding: JSONSerialization.data(withJSONObject: wire),as: UTF8.self)))
            let store = PostgresWorldRepository(client: first),reopened = PostgresWorldRepository(client: second)
            do {
                _ = try await MovementPublisher(actorID: actor,repository: LostMovementAcknowledgement(base: store)).publish(report,origin: .synthetic,deadline: .now.advanced(by: .seconds(4)))
                XCTFail("Expected lost acknowledgement")
            } catch { XCTAssertEqual(error as? WorldJournalError,.unavailable) }
            let committed = try await reopened.page(actorID: actor,afterSequence: 0,cursor: nil,limit: 10,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertEqual(committed.events.count,1)
            // Recover by ID only through a new store/client; input, policy and
            // origin are reconstructed from durable state rather than the report.
            let resumed = try await MovementEpochRecovery(store: reopenedEpochs,publisher: MovementPublisher(actorID: actor,repository: reopened)).recover(epochID: event.epochID,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertEqual(resumed.count,2)
            XCTAssertEqual(resumed[0],committed.events[0].draft.id)
            async let a = MovementPublisher(actorID: actor,repository: store).publish(report,origin: .synthetic,deadline: .now.advanced(by: .seconds(4)))
            async let b = MovementPublisher(actorID: actor,repository: reopened).publish(report,origin: .synthetic,deadline: .now.advanced(by: .seconds(4)))
            let duplicateResults = try await [a,b]
            XCTAssertTrue(duplicateResults.flatMap { $0 }.allSatisfy { !$0.created })
            let saved = try await reopened.page(actorID: actor,afterSequence: 0,cursor: nil,limit: 10,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertEqual(saved.events.count,2)
            XCTAssertEqual(Set(saved.events.map { $0.draft.id }).count,2)
            let draft = saved.events[0].draft
            XCTAssertEqual(draft.type,"perception.movement_confirmed")
            XCTAssertNil(draft.times.occurredAt)
            XCTAssertEqual(draft.confidence.value,0.8)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: draft.payload.bytes) as? [String:Any])
            XCTAssertEqual(payload["eventID"] as? String,report.events[0].id)
            XCTAssertEqual(payload["origin"] as? String,"synthetic")
            XCTAssertEqual(payload["confidenceMeaning"] as? String,"minimum_source_confidence")
            let confirmations = try XCTUnwrap(payload["confirmations"] as? [[String:Any]])
            XCTAssertEqual(confirmations.count,3)
            XCTAssertEqual(confirmations[0]["observationID"] as? String,report.events[0].confirmations[0].source.observationID.uuidString)
            do {
                _ = try await MovementPublisher(actorID: actor,repository: reopened).publish(report,origin: .sensor,deadline: .now.advanced(by: .seconds(4)))
                XCTFail("Changed provenance accepted")
            } catch { XCTAssertEqual(error as? WorldJournalError,.idempotencyConflict) }
            // Movement evidence does not become an asserted semantic location.
            let projector = PostgresLocationProjection(actorID: actor,client: second)
            for event in saved.events { try await projector.apply(event) }
            let checkpoint = try await projector.checkpoint()
            XCTAssertEqual(checkpoint.lastSequence,saved.events.last?.sequence)
            let facts = try await second.query("SELECT count(*) FROM spatial_facts WHERE actor_id=\(actor)").collect()
            XCTAssertEqual(try facts[0].decode(Int.self),0)
            let foreign = try await reopened.page(actorID: UUID(),afterSequence: 0,cursor: nil,limit: 10,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertTrue(foreign.events.isEmpty)
            do {
                _ = try await MovementPublisher(actorID: UUID(),repository: reopened).publish(report,origin: .synthetic,deadline: .now.advanced(by: .seconds(4)))
                XCTFail("Foreign publication accepted")
            } catch { XCTAssertEqual(error as? MovementPublicationError,.scopeMismatch) }
            let otherActor = UUID(),otherEntity = UUID(),unknown = try Self.report(actor: otherActor,entity: otherEntity,unknownFinalConfidence: true)
            do {
                _ = try await MovementPublisher(actorID: otherActor,repository: reopened).publish(unknown,origin: .synthetic,deadline: .now.advanced(by: .seconds(4)))
                XCTFail("Unknown confidence accepted")
            } catch { XCTAssertEqual(error as? MovementPublicationError,.unknownConfidence) }
            _ = try await second.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(otherEntity),\(otherActor),'fixture')").collect()
            let unknownEvent = unknown.events[0]
            let unknownEpoch = try MovementEpoch(detector: ConfirmedMovementDetector(actorID: otherActor,entityID: otherEntity,epochID: unknownEvent.epochID,entityType: unknownEvent.entityType,policy: unknownEvent.policy),samples: unknown.samples,origin: .synthetic)
            let unknownStore = PostgresMovementEpochStore(client: second,actorID: otherActor)
            try await unknownStore.save(unknownEpoch,deadline: .now.advanced(by: .seconds(4)))
            let unknownLoaded = try await unknownStore.load(epochID: unknownEvent.epochID,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertNil(unknownLoaded?.samples.last?.observation?.source.confidence)
            do {
                _ = try await MovementEpochRecovery(store: unknownStore,publisher: MovementPublisher(actorID: otherActor,repository: reopened)).recover(epochID: unknownEvent.epochID,deadline: .now.advanced(by: .seconds(4)))
                XCTFail("Unknown confidence fabricated during recovery")
            } catch { XCTAssertEqual(error as? MovementPublicationError,.unknownConfidence) }
            let absent = try await reopened.page(actorID: otherActor,afterSequence: 0,cursor: nil,limit: 10,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertTrue(absent.events.isEmpty,"Preflight must reject whole report before writing its valid first event")
        }
    }
}
