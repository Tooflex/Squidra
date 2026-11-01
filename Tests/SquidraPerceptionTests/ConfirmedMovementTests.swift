import Foundation
import SquidraDomain
import SquidraSpatial
import SquidraPerception
import XCTest

final class ConfirmedMovementTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        let actor = UUID(),entity = UUID(),epoch = UUID(),camera = UUID(),frameID = UUID(),calibrationID = UUID(),policyID = UUID()
        func frame(version: String = "1") throws -> SpatialCoordinateFrame {
            try SpatialCoordinateFrame(actorID: actor,id: frameID,up: .positiveZ,calibration: SpatialCalibration(id: calibrationID,version: version,maximumErrorMeters: 0))
        }
        func detector(displacement: Double = 0.1, duration: Double = 0.2) throws -> ConfirmedMovementDetector {
            try ConfirmedMovementDetector(actorID: actor,entityID: entity,epochID: epoch,entityType: "cup",
                policy: MovementPolicy(id: policyID,thresholdsByType: ["cup": MovementThreshold(minimumDisplacementMeters: displacement,minimumDurationSeconds: duration)]))
        }
        func sample(_ index: Int, x: Double, time: Double? = nil, error: Double = 0, association: SpatialAssociation = .confirmed,
                    geometry: SpatialGeometry? = nil, version: String = "1", entity: UUID? = nil, observationID: UUID? = nil) throws -> MovementSample {
            let instant = try UTCInstant(secondsSince1970: time ?? Double(index))
            let source = try SpatialSource(observationID: observationID ?? UUID(),cameraID: camera,imageFrameID: UUID(),modelID: "authored-scene",modelVersion: "1",
                times: ObservationTimestamps(occurredAt: nil,observedAt: instant,recordedAt: instant,timeZone: IANATimeZone(identifier: "Europe/Paris")),confidence: Confidence(0.8))
            return try MovementSample(observedAt: instant,observation: SpatialObservation(actorID: actor,entityID: entity ?? self.entity,coordinateFrameID: frameID,
                geometry: geometry ?? .calibrated3D(SpatialBox3D(lower: [x,0,0],upper: [x+0.1,0.1,0.1],maximumErrorMeters: error)),association: association,
                validity: SpatialValidity(from: instant,to: nil),source: source),frame: frame(version: version))
        }
    }
    func testRepeatedMovementEmitsOnceWithOriginalEvidenceAndStableReplayID() throws {
        let f = Fixture(),samples = try [f.sample(0,x: 0),f.sample(1,x: 0.2),f.sample(2,x: 0.201),f.sample(3,x: 0.199),f.sample(4,x: 0.2)]
        let report = try f.detector().evaluate(samples)
        XCTAssertEqual(report.events.count,1)
        let event = try XCTUnwrap(report.events.first)
        XCTAssertEqual(event.baseline,samples[0].observation)
        XCTAssertEqual(event.confirmations,samples[1...3].compactMap(\.observation))
        XCTAssertEqual(event.frame,try f.frame())
        XCTAssertGreaterThan(event.minimumDisplacementMeters,0.19)
        XCTAssertEqual(event.basis,"inferred")
        XCTAssertEqual(report.samples,samples)
        XCTAssertEqual(try f.detector().evaluate(samples).events.map(\.id),[event.id])
        let replayed = [samples[0],samples[1],samples[1]]+Array(samples[2...])
        XCTAssertEqual(try f.detector().evaluate(replayed).events.map(\.id),[event.id])
    }
    func testJitterAndInsufficientRepetitionNeverConfirm() throws {
        let f = Fixture()
        XCTAssertTrue(try f.detector().evaluate([f.sample(0,x: 0),f.sample(1,x: 0.01),f.sample(2,x: -0.01),f.sample(3,x: 0.005)]).events.isEmpty)
        XCTAssertTrue(try f.detector().evaluate([f.sample(0,x: 0),f.sample(1,x: 0.2),f.sample(2,x: 0.2)]).events.isEmpty)
        XCTAssertTrue(try f.detector(duration: 1).evaluate([f.sample(0,x: 0,time: 0),f.sample(1,x: 0.2,time: 0.1),f.sample(2,x: 0.2,time: 0.2),f.sample(3,x: 0.2,time: 0.3)]).events.isEmpty)
    }
    func testOcclusionGapFrameAndAmbiguousIdentityResetBaseline() throws {
        let f = Fixture()
        let before = try [f.sample(0,x: 0),f.sample(1,x: 0.2)]
        let after = try [f.sample(3,x: 0.2),f.sample(4,x: 0.2),f.sample(5,x: 0.2)]
        let absent = try MovementSample(observedAt: UTCInstant(secondsSince1970: 2),observation: nil,frame: nil)
        let candidate = try f.sample(2,x: 0.2,association: .candidate)
        let uncalibrated = try f.sample(2,x: 0.2,geometry: .uncalibrated2D)
        for interrupted in [absent,candidate,uncalibrated] {
            XCTAssertTrue(try f.detector().evaluate(before+[interrupted]+after).events.isEmpty)
        }
        XCTAssertTrue(try f.detector().evaluate(before+[f.sample(10,x: 0.2),f.sample(11,x: 0.2),f.sample(12,x: 0.2)]).events.isEmpty)
        let changed = try [f.sample(2,x: 0.2,version: "2"),f.sample(3,x: 0.2,version: "2"),f.sample(4,x: 0.2,version: "2")]
        XCTAssertTrue(try f.detector().evaluate(before+changed).events.isEmpty)
    }
    func testSimultaneousContradictionsRemainVisibleAndDoNotChooseInputOrder() throws {
        let f = Fixture(),a = try f.sample(2,x: 0.2),b = try f.sample(2,x: 0.8)
        let prefix = try [f.sample(0,x: 0),f.sample(1,x: 0.2)],suffix = try [f.sample(3,x: 0.2),f.sample(4,x: 0.2),f.sample(5,x: 0.2)]
        for middle in [[a,b],[b,a]] {
            let report = try f.detector().evaluate(prefix+middle+suffix)
            XCTAssertTrue(report.events.isEmpty)
            XCTAssertEqual(report.abstentions.filter { $0.reason == .contradiction }.count,2)
            XCTAssertEqual(report.samples.count,7)
        }
    }
    func testUnstableDestinationAndMeasurementUncertaintyCannotConfirm() throws {
        let f = Fixture()
        XCTAssertTrue(try f.detector().evaluate([f.sample(0,x: 0),f.sample(1,x: 0.2),f.sample(2,x: 0.4),f.sample(3,x: 0.2)]).events.isEmpty)
        XCTAssertTrue(try f.detector().evaluate([f.sample(0,x: 0,error: 0.1),f.sample(1,x: 0.2,error: 0.1),f.sample(2,x: 0.2,error: 0.1),f.sample(3,x: 0.2,error: 0.1)]).events.isEmpty)
        XCTAssertTrue(try f.detector().evaluate([f.sample(0,x: 0),f.sample(1,x: 0.1),f.sample(2,x: 0.1),f.sample(3,x: 0.1)]).events.isEmpty)
    }
    func testSecondConfirmedMovementUsesNewBaselineAndDistinctEvent() throws {
        let f = Fixture(),samples = try [f.sample(0,x: 0),f.sample(1,x: 0.2),f.sample(2,x: 0.2),f.sample(3,x: 0.2),f.sample(4,x: 0.5),f.sample(5,x: 0.5),f.sample(6,x: 0.5)]
        let events = try f.detector().evaluate(samples).events
        XCTAssertEqual(events.count,2)
        XCTAssertNotEqual(events[0].id,events[1].id)
        XCTAssertEqual(events[1].baseline,samples[3].observation)
        XCTAssertTrue(try f.detector(displacement: 0.8).evaluate(samples).events.isEmpty)
    }
    func testScopeOrderingConflictingIDsAndCapacityFailClosed() throws {
        let f = Fixture(),first = try f.sample(0,x: 0)
        XCTAssertThrowsError(try f.detector().evaluate([first,f.sample(1,x: 0.2,entity: UUID())]))
        XCTAssertThrowsError(try f.detector().evaluate([f.sample(2,x: 0),first]))
        XCTAssertThrowsError(try f.detector().evaluate([first,f.sample(0,x: 0.2,observationID: first.observation!.source.observationID)])) { XCTAssertEqual($0 as? MovementError,.conflictingObservation) }
        XCTAssertThrowsError(try f.detector().evaluate(Array(repeating: first,count: 1025))) { XCTAssertEqual($0 as? MovementError,.capacityExceeded) }
    }
    func testInvalidThresholdsAndUnknownEntityTypeAreRejected() throws {
        for value in [Double.nan,Double.infinity,0,-1] { XCTAssertThrowsError(try MovementThreshold(minimumDisplacementMeters: value)) }
        XCTAssertThrowsError(try MovementThreshold(minimumDisplacementMeters: 0.1,confirmations: 1))
        XCTAssertThrowsError(try MovementThreshold(minimumDisplacementMeters: 0.1,minimumDurationSeconds: 0))
        XCTAssertThrowsError(try MovementPolicy(id: UUID(),thresholdsByType: [:]))
        let f = Fixture(),policy = try MovementPolicy(id: UUID(),thresholdsByType: ["cup": MovementThreshold(minimumDisplacementMeters: 0.1)])
        XCTAssertThrowsError(try ConfirmedMovementDetector(actorID: f.actor,entityID: f.entity,epochID: f.epoch,entityType: "unknown",policy: policy))
    }
    func testOneImageCannotCountAsRepeatedTemporalEvidence() throws {
        let f = Fixture(),first = try f.sample(0,x: 0),second = try f.sample(1,x: 0.2)
        let old = second.observation!,source = old.source
        let copiedSource = try SpatialSource(observationID: source.observationID,cameraID: source.cameraID,
            imageFrameID: first.observation!.source.imageFrameID,modelID: source.modelID,modelVersion: source.modelVersion,times: source.times,confidence: source.confidence)
        let copied = SpatialObservation(actorID: old.actorID,entityID: old.entityID,coordinateFrameID: old.coordinateFrameID,
            geometry: old.geometry,association: old.association,validity: old.validity,source: copiedSource)
        XCTAssertThrowsError(try f.detector().evaluate([first,MovementSample(observedAt: second.observedAt,observation: copied,frame: second.frame)])) {
            XCTAssertEqual($0 as? MovementError,.conflictingObservation)
        }
    }
    func testCancellationProducesNoPartialReport() async throws {
        let f = Fixture(),detector = try f.detector(),samples = try [f.sample(0,x: 0)]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try detector.evaluate(samples)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? MovementError,.cancelled) }
    }

}
