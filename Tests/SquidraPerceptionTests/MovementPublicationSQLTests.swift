import Foundation
import PostgresNIO
import SquidraDomain
import SquidraSpatial
import SquidraPerception
import SquidraPostgres
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
            let store = PostgresWorldRepository(client: first),reopened = PostgresWorldRepository(client: second)
            do {
                _ = try await MovementPublisher(actorID: actor,repository: LostMovementAcknowledgement(base: store)).publish(report,origin: .synthetic,deadline: .now.advanced(by: .seconds(4)))
                XCTFail("Expected lost acknowledgement")
            } catch { XCTAssertEqual(error as? WorldJournalError,.unavailable) }
            let committed = try await reopened.page(actorID: actor,afterSequence: 0,cursor: nil,limit: 10,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertEqual(committed.events.count,1)
            let resumed = try await MovementPublisher(actorID: actor,repository: reopened).publish(report,origin: .synthetic,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertEqual(resumed.map(\.created),[false,true])
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
            let absent = try await reopened.page(actorID: otherActor,afterSequence: 0,cursor: nil,limit: 10,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertTrue(absent.events.isEmpty,"Preflight must reject whole report before writing its valid first event")
        }
    }
}
