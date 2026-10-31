import Foundation
import SquidraDomain
import SquidraSpatial
import XCTest

final class CalibratedRelationTests: XCTestCase {
    private struct Scene {
        let actor = UUID(),frameID = UUID()
        var calibration: SpatialCalibration { get throws { try SpatialCalibration(id:UUID(),version:"fixture-calibration-1",maximumErrorMeters:0) } }
        var policy: SpatialRelationPolicy { get throws { try SpatialRelationPolicy(id:UUID()) } }
        func frame(_ up:SpatialUpAxis = .positiveZ,calibrationError:Double = 0) throws -> SpatialCoordinateFrame {
            SpatialCoordinateFrame(actorID:actor,id:frameID,up:up,calibration:try SpatialCalibration(id:UUID(),version:"fixture-calibration-1",maximumErrorMeters:calibrationError))
        }
        func observation(_ lower:[Double] = [0,0,0],_ upper:[Double] = [1,1,1],error:Double = 0,
                         geometry:SpatialGeometry? = nil,actor:UUID? = nil,entity:UUID = UUID(),frame:UUID? = nil,
                         association:SpatialAssociation = .confirmed,from:Double = 0,to:Double? = nil,confidence:Double? = 0.8) throws -> SpatialObservation {
            let instant = try UTCInstant(secondsSince1970:100),zone = try IANATimeZone(identifier:"Europe/Paris")
            let source = try SpatialSource(observationID:UUID(),cameraID:UUID(),imageFrameID:UUID(),modelID:"authored-3d-scene",modelVersion:"1",
                times:ObservationTimestamps(occurredAt:nil,observedAt:instant,recordedAt:instant,timeZone:zone),confidence:confidence.map(Confidence.init))
            return try SpatialObservation(actorID:actor ?? self.actor,entityID:entity,coordinateFrameID:frame ?? frameID,
                geometry:geometry ?? .calibrated3D(SpatialBox3D(lower:lower,upper:upper,maximumErrorMeters:error)),association:association,
                validity:SpatialValidity(from:UTCInstant(secondsSince1970:from),to:to.map { try UTCInstant(secondsSince1970:$0) }),source:source)
        }
        func evaluate(_ subject:SpatialObservation,_ object:SpatialObservation,frame:SpatialCoordinateFrame? = nil) throws -> SpatialRelationResult {
            try CalibratedRelationExtractor(actorID:actor,policy:policy).evaluate(subject:subject,object:object,frame:frame ?? self.frame())
        }
    }
    func testNextToUsesSeparatedHorizontalSurfacesAndVerticalOverlap() throws {
        let scene = Scene(),a = try scene.observation(),near = try scene.observation([1.1,0,0],[2.1,1,1])
        XCTAssertEqual(try scene.evaluate(a,near).relations.map(\.predicate),[.nextTo])
        XCTAssertEqual(try scene.evaluate(near,a).relations.map(\.predicate),[.nextTo])
        for distant in try [scene.observation([1.3,0,0],[2.3,1,1]),scene.observation([1.1,0,2],[2.1,1,3]),scene.observation([0.5,0,0],[1.5,1,1])] {
            XCTAssertEqual(try scene.evaluate(a,distant).abstention,.noConservativeRule)
        }
    }
    func testOnTopOfRequiresContactSupportAndCorrectDirection() throws {
        let scene = Scene(),base = try scene.observation(),top = try scene.observation([0.2,0.2,1],[0.8,0.8,2])
        XCTAssertEqual(try scene.evaluate(top,base).relations.map(\.predicate),[.onTopOf])
        XCTAssertEqual(try scene.evaluate(base,top).abstention,.noConservativeRule)
        for unsupported in try [scene.observation([0.2,0.2,1.02],[0.8,0.8,2.02]),scene.observation([0.99,0,1],[1.99,1,2]),scene.observation([0.2,0.2,0.5],[0.8,0.8,1.5])] {
            XCTAssertEqual(try scene.evaluate(unsupported,base).abstention,.noConservativeRule)
        }
    }
    func testInsideRequiresAllThreeDimensionsAndConservativeClearance() throws {
        let scene = Scene(),container = try scene.observation(),small = try scene.observation([0.2,0.2,0.2],[0.8,0.8,0.8])
        XCTAssertEqual(try scene.evaluate(small,container).relations.map(\.predicate),[.inside])
        XCTAssertEqual(try scene.evaluate(container,small).abstention,.noConservativeRule)
        for outside in try [scene.observation([0,0.2,0.2],[0.8,0.8,0.8]),scene.observation([0.2,0.2,-0.1],[0.8,0.8,0.8]),scene.observation([0.2,0.2,0.2],[0.8,0.8,0.8],error:0.21)] {
            XCTAssertEqual(try scene.evaluate(outside,container).abstention,.noConservativeRule)
        }
    }
    func testSignedUpAxesUseExplicitIndependentControlledScenes() throws {
        let scene = Scene(),base = try scene.observation()
        let placements:[(SpatialUpAxis,[Double],[Double])] = [
            (.positiveX,[1,0.2,0.2],[2,0.8,0.8]),(.negativeX,[-1,0.2,0.2],[0,0.8,0.8]),
            (.positiveY,[0.2,1,0.2],[0.8,2,0.8]),(.negativeY,[0.2,-1,0.2],[0.8,0,0.8]),
            (.positiveZ,[0.2,0.2,1],[0.8,0.8,2]),(.negativeZ,[0.2,0.2,-1],[0.8,0.8,0])]
        for (axis,lower,upper) in placements {
            let result = try scene.evaluate(scene.observation(lower,upper),base,frame:scene.frame(axis))
            XCTAssertEqual(result.relations.map(\.predicate),[.onTopOf])
        }
    }
    func testCalibrationAndMeasurementUncertaintyCannotBeIgnoredAtThresholds() throws {
        let scene = Scene(),base = try scene.observation(),top = try scene.observation([0.2,0.2,1],[0.8,0.8,2])
        XCTAssertEqual(try scene.evaluate(top,base,frame:scene.frame(calibrationError:0.01)).abstention,.noConservativeRule)
        let uncertainNear = try scene.observation([1.1,0,0],[2.1,1,1],error:0.11)
        XCTAssertEqual(try scene.evaluate(uncertainNear,base).abstention,.noConservativeRule)
        let threshold = try scene.observation([1.25,0,0],[2.25,1,1])
        XCTAssertEqual(try scene.evaluate(threshold,base).abstention,.noConservativeRule)
        let justInside = try scene.observation([1.24999,0,0],[2.24999,1,1])
        XCTAssertEqual(try scene.evaluate(justInside,base).relations.map(\.predicate),[.nextTo])
    }
    func testMissingEvidenceAndAmbiguousIdentityAbstainWithoutInventingDistance() throws {
        let scene = Scene(),base = try scene.observation(),frame = try scene.frame(),extractor = try CalibratedRelationExtractor(actorID:scene.actor,policy:scene.policy)
        XCTAssertEqual(extractor.evaluate(subject:base,object:try scene.observation(),frame:nil).abstention,.missingFrame)
        XCTAssertEqual(try scene.evaluate(base,scene.observation(geometry:.missingDepth)).abstention,.missingDepth)
        XCTAssertEqual(try scene.evaluate(base,scene.observation(geometry:.uncalibrated2D)).abstention,.uncalibrated2D)
        XCTAssertEqual(try scene.evaluate(base,scene.observation(association:.candidate)).abstention,.ambiguousAssociation)
        XCTAssertEqual(try scene.evaluate(base,scene.observation(entity:base.entityID)).abstention,.sameEntity)
        let uncalibrated = SpatialCoordinateFrame(actorID:scene.actor,id:frame.id,up:.positiveZ,calibration:nil)
        XCTAssertEqual(try scene.evaluate(base,scene.observation(),frame:uncalibrated).abstention,.missingCalibration)
    }
    func testActorAndFrameMismatchNeverTransformOrMixEvidence() throws {
        let scene = Scene(),base = try scene.observation()
        XCTAssertEqual(try scene.evaluate(base,scene.observation(actor:UUID())).abstention,.scopeMismatch)
        XCTAssertEqual(try scene.evaluate(base,scene.observation(frame:UUID())).abstention,.scopeMismatch)
        let foreign = SpatialCoordinateFrame(actorID:UUID(),id:scene.frameID,up:.positiveZ,calibration:try scene.calibration)
        XCTAssertEqual(try scene.evaluate(base,scene.observation(),frame:foreign).abstention,.scopeMismatch)
        let missing = SpatialObservation(actorID:scene.actor,entityID:UUID(),coordinateFrameID:nil,geometry:base.geometry,association:.confirmed,validity:base.validity,source:base.source)
        XCTAssertEqual(try scene.evaluate(base,missing).abstention,.missingFrame)
    }
    func testHalfOpenValidityProvenanceAndUnknownConfidenceRemainExplicit() throws {
        let scene = Scene(),base = try scene.observation(from:0,to:10,confidence:0.9),top = try scene.observation([0.2,0.2,1],[0.8,0.8,2],from:5,to:20,confidence:0.6),frame = try scene.frame()
        let result = try scene.evaluate(top,base,frame:frame),relation = try XCTUnwrap(result.relations.first)
        XCTAssertEqual(relation.validity,try SpatialValidity(from:UTCInstant(secondsSince1970:5),to:UTCInstant(secondsSince1970:10)))
        XCTAssertEqual(relation.subjectSource,top.source);XCTAssertEqual(relation.objectSource,base.source)
        XCTAssertNil(relation.subjectSource.times.occurredAt);XCTAssertEqual(relation.subjectSource.times.timeZone.identifier,"Europe/Paris")
        XCTAssertEqual(relation.calibration,frame.calibration);XCTAssertEqual(relation.coordinateFrameID,scene.frameID)
        XCTAssertEqual(relation.actorID,scene.actor);XCTAssertEqual(relation.basis,"inferred");XCTAssertEqual(relation.confidence?.value,0.6)
        let later = try scene.observation([0.2,0.2,1],[0.8,0.8,2],from:10,confidence:nil)
        XCTAssertEqual(try scene.evaluate(later,base).abstention,.disjointValidity)
        let unknown = try scene.observation([0.2,0.2,1],[0.8,0.8,2],confidence:nil)
        let unknownRelation = try XCTUnwrap(scene.evaluate(unknown,base).relations.first)
        XCTAssertNil(unknownRelation.confidence)
    }
    func testNonfiniteDegenerateAndUnboundedContractsAreRejected() throws {
        for lower in [[Double.nan,0,0],[Double.infinity,0,0],[-1_000_001,0,0],[0,0]] {
            XCTAssertThrowsError(try SpatialBox3D(lower:lower,upper:[1,1,1],maximumErrorMeters:0))
        }
        XCTAssertThrowsError(try SpatialBox3D(lower:[0,0,0],upper:[1,1,0],maximumErrorMeters:0))
        XCTAssertThrowsError(try SpatialBox3D(lower:[0,0,0],upper:[1,1,1],maximumErrorMeters:Double.nan))
        XCTAssertThrowsError(try SpatialRelationPolicy(id:UUID(),nextToMaximumGapMeters:Double.infinity))
        XCTAssertThrowsError(try SpatialRelationPolicy(id:UUID(),minimumFootprintOverlap:0))
        XCTAssertThrowsError(try SpatialCalibration(id:UUID(),version:"bad\nversion",maximumErrorMeters:0))
        let time = try UTCInstant(secondsSince1970:0)
        XCTAssertThrowsError(try SpatialValidity(from:time,to:time))
    }
}
