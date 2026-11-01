import Foundation
import SquidraDomain
import SquidraPerception
import SquidraSpatial
import XCTest

private actor SceneStore: EntityAssociationStore {
    var state: EntityAssociationState?
    func load(actorID: UUID, cameraID: UUID, deadline: ContinuousClock.Instant) -> EntityAssociationState? { state }
    func compareAndSwap(_ state: EntityAssociationState, expectedRevision: Int64?, deadline: ContinuousClock.Instant) throws {
        guard self.state?.revision == expectedRevision else { throw EntityAssociationError.conflict }
        self.state = state
    }
}
private struct SceneVision: VisionModel {
    let count: Int
    let identity = try! VisionIdentity(modelID: "authored.scene", version: "1", deployment: .synthetic)
    func detect(_ request: VisionRequest) throws -> VisionOutput {
        let detections = try (0..<count).map { i in
            try VisionDetection(localID: "object-\(i)", label: "object", box: PixelBox(x: 0,y: 0,width: 1,height: 1),
                mask: BinaryMask(width: 8,height: 8,pixels: Data([1] + Array(repeating: 0,count: 63))),
                confidence: Confidence(i == 0 ? 0.9 : 0.7), appearance: (0..<count).map { $0 == i ? 1.0 : 0.0 })
        }
        return VisionOutput(identity: identity,context: request.context,imageSHA256: request.imageSHA256,detections: detections)
    }
}
final class ResolvedSceneTests: XCTestCase, @unchecked Sendable {
    private struct Scene {
        let frame: ImportedFrame, resolution: EntityResolution, coordinate: SpatialCoordinateFrame
        var extractor: SceneRelationExtractor { get throws { try SceneRelationExtractor(actorID: frame.context.actorID,policy: SpatialRelationPolicy(id: UUID())) } }
        func evidence(_ geometry: SpatialGeometry = .missingDepth) throws -> [DetectionSpatialEvidence] {
            try frame.detections.map { DetectionSpatialEvidence(localID: $0.localID,observationID: UUID(),geometry: geometry,
                validity: try SpatialValidity(from: UTCInstant(secondsSince1970: 100),to: UTCInstant(secondsSince1970: 102))) }
        }
        func evaluate(_ evidence: [DetectionSpatialEvidence], coordinate: SpatialCoordinateFrame? = nil) throws -> ResolvedSceneRelations {
            try extractor.evaluate(frame: frame,resolution: resolution,evidenceContext: frame.context,evidence: evidence,coordinateFrame: coordinate ?? self.coordinate)
        }
    }
    private func scene(count: Int = 2, matched: Bool = true) async throws -> Scene {
        let actor = UUID(),camera = UUID(),store = SceneStore()
        let resolver = try ContinuityEntityResolver(store: store,policy: AssociationPolicy())
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixtures/providers/vision-synthetic.v1.json"))) as? [String:Any])
        let frames = try XCTUnwrap(object["frames"] as? [[String:Any]])
        let image = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(frames[0]["imageBase64"] as? String)))
        func ingest(_ time: Double) async throws -> ImportedFrame {
            let instant = try UTCInstant(secondsSince1970: time)
            let context = try FrameContext(actorID: actor,cameraID: camera,frameID: UUID(),timestamps:
                ObservationTimestamps(occurredAt: nil,observedAt: instant,recordedAt: instant,timeZone: IANATimeZone(identifier: "Europe/Paris")))
            return try await FrameImporter(model: SceneVision(count: count)).ingest(bytes: image,mediaType: "image/png",context: context,
                consent: FrameImportConsent(actorID: actor,cameraID: camera,permitsLocalProcessing: true,permitsCloudTransfer: false,expiresAt: .now.advanced(by: .seconds(10))),deadline: .now.advanced(by: .seconds(5)))
        }
        let first = try await ingest(100)
        let initial = try await resolver.resolve(first,deadline: .now.advanced(by: .seconds(5)))
        let frame = try await matched ? ingest(101) : first
        let resolution = try await matched ? resolver.resolve(frame,deadline: .now.advanced(by: .seconds(5))) : initial
        return Scene(frame: frame,resolution: resolution,coordinate: SpatialCoordinateFrame(actorID: actor,id: UUID(),up: .positiveZ,
            calibration: try SpatialCalibration(id: UUID(),version: "authored-depth-1",maximumErrorMeters: 0)))
    }
    func testImportedAssociatedScenesProduceThreeDirectionalRulesWithCompleteProvenance() async throws {
        let scene = try await scene()
        let base = try SpatialBox3D(lower: [0,0,0],upper: [1,1,1],maximumErrorMeters: 0)
        let cases: [(SpatialPredicate,[Double],[Double])] = [(.inside,[0.2,0.2,0.2],[0.8,0.8,0.8]),(.onTopOf,[0.2,0.2,1],[0.8,0.8,2]),(.nextTo,[1.1,0,0],[2.1,1,1])]
        for (predicate,lower,upper) in cases {
            let original = try scene.evidence(.calibrated3D(base))
            let evidence = [DetectionSpatialEvidence(localID: original[0].localID,observationID: original[0].observationID,
                geometry: .calibrated3D(try SpatialBox3D(lower: lower,upper: upper,maximumErrorMeters: 0)),validity: original[0].validity),original[1]]
            let report = try scene.evaluate(evidence)
            XCTAssertEqual(report.pairs.count,2)
            XCTAssertEqual(report.pairs[0].result.relations.map(\.predicate),[predicate])
            XCTAssertEqual(report.pairs[1].result.relations.map(\.predicate),predicate == .nextTo ? [.nextTo] : [])
            let relation = try XCTUnwrap(report.relations.first)
            XCTAssertEqual(relation.subjectID,scene.resolution.assignments[0].entityID)
            XCTAssertEqual(relation.subjectSource.observationID,evidence[0].observationID)
            XCTAssertEqual(relation.subjectSource.times,scene.frame.context.timestamps)
            XCTAssertEqual(relation.subjectSource.cameraID,scene.frame.context.cameraID)
            XCTAssertEqual(relation.subjectSource.imageFrameID,scene.frame.context.frameID)
            XCTAssertEqual(relation.coordinateFrameID,scene.coordinate.id)
            XCTAssertEqual(relation.calibration,scene.coordinate.calibration)
            XCTAssertEqual(relation.validity,evidence[0].validity)
            XCTAssertEqual(relation.confidence?.value,0.7)
            XCTAssertEqual(relation.basis,"inferred")
            XCTAssertEqual(report.resolution,scene.resolution)
            XCTAssertTrue(report.resolution.synthetic)
        }
    }
    func testCandidateIdentitiesNeverBecomeConfirmedSpatialFacts() async throws {
        let scene = try await scene(matched: false)
        let report = try scene.evaluate(scene.evidence())
        XCTAssertTrue(report.relations.isEmpty)
        XCTAssertTrue(report.pairs.allSatisfy { $0.result.abstention == .ambiguousAssociation })
    }
    func testMissingDepthFrameCalibrationAnd2DMasksAbstain() async throws {
        let scene = try await scene()
        for (geometry,reason) in [(SpatialGeometry.missingDepth,SpatialAbstention.missingDepth),(.uncalibrated2D,.uncalibrated2D)] {
            XCTAssertTrue(try scene.evaluate(scene.evidence(geometry)).pairs.allSatisfy { $0.result.abstention == reason })
        }
        let evidence = try scene.evidence()
        let missing = try scene.extractor.evaluate(frame: scene.frame,resolution: scene.resolution,evidenceContext: scene.frame.context,evidence: evidence,coordinateFrame: nil)
        XCTAssertTrue(missing.pairs.allSatisfy { $0.result.abstention == .missingFrame })
        let uncalibrated = SpatialCoordinateFrame(actorID: scene.frame.context.actorID,id: scene.coordinate.id,up: .positiveZ,calibration: nil)
        XCTAssertTrue(try scene.evaluate(evidence,coordinate: uncalibrated).pairs.allSatisfy { $0.result.abstention == .missingCalibration })
    }
    func testMismatchedImageScopeDuplicateOrIncompleteEvidenceIsRejected() async throws {
        let scene = try await scene(),evidence = try scene.evidence()
        let foreign = FrameContext(actorID: UUID(),cameraID: scene.frame.context.cameraID,frameID: scene.frame.context.frameID,timestamps: scene.frame.context.timestamps)
        XCTAssertThrowsError(try scene.extractor.evaluate(frame: scene.frame,resolution: scene.resolution,evidenceContext: foreign,evidence: evidence,coordinateFrame: scene.coordinate))
        let stale = FrameContext(actorID: scene.frame.context.actorID,cameraID: scene.frame.context.cameraID,frameID: UUID(),timestamps: scene.frame.context.timestamps)
        XCTAssertThrowsError(try scene.extractor.evaluate(frame: scene.frame,resolution: scene.resolution,evidenceContext: stale,evidence: evidence,coordinateFrame: scene.coordinate))
        let wrongHash = try EntityResolution(context: scene.frame.context,identity: scene.frame.identity,imageSHA256: String(repeating: "0",count: 64),assignments: scene.resolution.assignments)
        XCTAssertThrowsError(try scene.extractor.evaluate(frame: scene.frame,resolution: wrongHash,evidenceContext: scene.frame.context,evidence: evidence,coordinateFrame: scene.coordinate))
        for invalid in [Array(evidence.prefix(1)),[evidence[0],evidence[0]]] { XCTAssertThrowsError(try scene.evaluate(invalid)) }
        let expired = try SpatialValidity(from: UTCInstant(secondsSince1970: 99),to: UTCInstant(secondsSince1970: 101))
        XCTAssertThrowsError(try scene.evaluate([DetectionSpatialEvidence(localID: evidence[0].localID,observationID: UUID(),geometry: .missingDepth,validity: expired),evidence[1]]))
    }
    func testSceneCapacityRejectsRatherThanTruncatesAndEmptySceneIsExplicit() async throws {
        let empty = try await scene(count: 0)
        XCTAssertTrue(try empty.evaluate([]).pairs.isEmpty)
        let full = try await scene(count: 32)
        XCTAssertEqual(try full.evaluate(full.evidence()).pairs.count,992)
        let oversized = try await scene(count: 33)
        XCTAssertThrowsError(try oversized.evaluate(oversized.evidence())) { XCTAssertEqual($0 as? SceneRelationError,.capacityExceeded) }
    }
    func testCancelledSceneDoesNotProducePartialResults() async throws {
        let scene = try await scene(),evidence = try scene.evidence()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try scene.evaluate(evidence)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? SceneRelationError,.cancelled) }
    }
}
