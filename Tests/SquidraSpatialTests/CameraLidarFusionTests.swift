import Foundation
import XCTest
import SquidraDomain
@testable import SquidraSpatial

final class CameraLidarFusionTests: XCTestCase, @unchecked Sendable {
    private let actor=UUID(),lidar=UUID(),camera=UUID(),map=UUID()
    private var root: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func fixture() throws -> [String:Any] { try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("fixtures/fusion/rectified-rig.v1.json"))) as? [String:Any]) }
    private func point(_ a: [Double]) throws -> FusionPoint { try FusionPoint(a[0],a[1],a[2]) }
    private func rig(translation: FusionPoint? = nil, mapFrom: UUID? = nil, checks: [FusionCalibrationCheck]? = nil) throws -> FusionCalibration {
        let rows=try XCTUnwrap(fixture()["checks"] as? [[String:Any]])
        let anchors=try checks ?? rows.map { row in
            let pixel=row["pixel"] as! [Double]
            return try FusionCalibrationCheck(lidar:point(row["lidar"] as! [Double]),map:point(row["map"] as! [Double]),u:pixel[0],v:pixel[1])
        }
        return try FusionCalibration(actorID:actor,id:UUID(),version:"authored-rig-1",
            intrinsics:FusionIntrinsics(width:8,height:8,fx:8,fy:8,cx:3.5,cy:3.5,maximumPixelError:0.01),
            lidarToCamera:FusionTransform(from:lidar,to:camera,rotation:[0,-1,0,1,0,0,0,0,1],translation:translation ?? FusionPoint(0.2,-0.1,0.3),maximumErrorMeters:0.001),
            cameraToMap:FusionTransform(from:mapFrom ?? camera,to:map,rotation:[0,0,1,0,1,0,-1,0,0],translation:FusionPoint(10,20,30),maximumErrorMeters:0.001),
            validFrom:UTCInstant(secondsSince1970:999),validUntil:UTCInstant(secondsSince1970:1001),maximumRangeMeters:100,checks:anchors,metricTolerance:1e-6,pixelTolerance:1e-6)
    }
    private func image(actorID: UUID? = nil, coordinateFrameID: UUID? = nil, time: Double = 1000) throws -> FusionCameraFrame {
        try FusionCameraFrame(actorID:actorID ?? actor,coordinateFrameID:coordinateFrameID ?? camera,frameID:UUID(),observedAt:UTCInstant(secondsSince1970:time),width:8,height:8,rectifiedRGB:Data(fixture()["rgb"] as! [UInt8]))
    }
    private func sample(_ xyz: [Double], time: Double = 1000.002, error: Double = 0.004, id: UUID = UUID()) throws -> FusionLidarPoint {
        try FusionLidarPoint(id:id,position:point(xyz),observedAt:UTCInstant(secondsSince1970:time),maximumErrorMeters:error)
    }
    private func fuse(_ points: [FusionLidarPoint], image: FusionCameraFrame? = nil, lidarID: UUID? = nil, owner: UUID? = nil,
                      deadline: ContinuousClock.Instant = .now.advanced(by:.seconds(5))) throws -> FusionMetricMap {
        try CameraLidarFusion(calibration:rig(),maximumTimestampSkewSeconds:0.01,maximumSceneSpeedMetersPerSecond:1)
            .fuse(camera:image ?? self.image(),lidarActorID:owner ?? actor,lidarCoordinateFrameID:lidarID ?? lidar,lidarFrameID:UUID(),points:points,deadline:deadline)
    }
    func testHeldOutMetricMapColorErrorUncertaintyAndLatencyAreExported() throws {
        let data=try fixture(),rows=try XCTUnwrap(data["samples"] as? [[String:Any]])
        let points=try rows.map { try sample($0["lidar"] as! [Double]) }
        let result=try fuse(points)
        XCTAssertEqual(result.actorID,actor);XCTAssertEqual(result.coordinateFrameID,map);XCTAssertEqual(result.points.count,4)
        var squared=0.0,maximum=0.0,bound=0.0
        for (output,row) in zip(result.points,rows) {
            let truth=row["expectedMap"] as! [Double],pixel=row["pixel"] as! [Int]
            let deltas=zip(output.position.values,truth).map { abs($0-$1) }
            let error=sqrt(deltas.reduce(0) { $0+$1*$1 })
            squared += error*error;maximum=max(maximum,error);bound=max(bound,output.maximumErrorMeters)
            XCTAssertLessThanOrEqual(deltas.max()!,output.maximumErrorMeters)
            XCTAssertEqual(output.colorState,.fused);XCTAssertEqual(output.pixelX,pixel[0]);XCTAssertEqual(output.pixelY,pixel[1])
            XCTAssertEqual(output.rgb,[UInt8(pixel[0]*30),UInt8(pixel[1]*30),123])
            XCTAssertEqual(output.observedAt,"1970-01-01T00:16:40.002000Z")
        }
        XCTAssertGreaterThan(result.processingNanoseconds,0);XCTAssertGreaterThan(maximum,0)
        let report:[String:Any] = ["schemaVersion":1,"fixture":"rectified-rig.v1.json","provenance":data["provenance"]!,
            "measuredAt":ISO8601DateFormatter().string(from:Date()),"hostOS":ProcessInfo.processInfo.operatingSystemVersionString,"build":"Swift debug test; fusion only, excludes parsing/rectification/encoding",
            "pointCount":rows.count,"rmseMeters":sqrt(squared/Double(rows.count)),"maximumErrorMeters":maximum,
            "maximumCoordinateUncertaintyMeters":bound,"coveredPointCount":4,"coloredPointCount":4,
            "processingNanoseconds":result.processingNanoseconds,"maximumTimestampSkewSeconds":result.maximumTimestampSkewSeconds,
            "calibrationMetricResidualMeters":try rig().validationMaximumMetricError,"calibrationPixelResidual":try rig().validationMaximumPixelError,
            "thresholdBasis":"fixture checks only; no SRS latency or accuracy threshold asserted"]
        let directory=root.appendingPathComponent(".build/fusion");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("report.json"),options:.atomic)
        try JSONEncoder().encode(result).write(to:directory.appendingPathComponent("metric-map.json"),options:.atomic)
    }
    func testRigidTransformsCalibrationCorrespondencesAndSupportRejectInconsistency() throws {
        for rotation in [[1,0,0,0,1,0,0,0,-1],[2,0,0,0,1,0,0,0,1],[Double.nan,0,0,0,1,0,0,0,1],[1,0]] {
            XCTAssertThrowsError(try FusionTransform(from:lidar,to:camera,rotation:rotation,translation:point([0,0,0]),maximumErrorMeters:0))
        }
        XCTAssertThrowsError(try rig(translation:point([0.21,-0.1,0.3])))
        XCTAssertThrowsError(try rig(mapFrom:UUID()))
        let badPixels=try (fixture()["checks"] as! [[String:Any]]).map { row in
            let pixel=row["pixel"] as! [Double]
            return try FusionCalibrationCheck(lidar:point(row["lidar"] as! [Double]),map:point(row["map"] as! [Double]),u:pixel[0]+0.1,v:pixel[1])
        }
        XCTAssertThrowsError(try rig(checks:badPixels))
        let repeated=try FusionCalibrationCheck(lidar:point([0,0,1.7]),map:point([12,19.9,29.8]),u:4.3,v:3.1)
        XCTAssertThrowsError(try rig(checks:Array(repeating:repeated,count:4)))
        XCTAssertThrowsError(try FusionIntrinsics(width:8,height:8,fx:0,fy:8,cx:3.5,cy:3.5,maximumPixelError:0))
        XCTAssertThrowsError(try FusionPoint(.infinity,0,0))
        let r=try rig();XCTAssertLessThanOrEqual(r.validationMaximumMetricError,1e-6);XCTAssertLessThanOrEqual(r.validationMaximumPixelError,1e-6)
    }
    func testActorFrameImageBoundsAndTimestampMismatchRejectWholeCapture() throws {
        let p=try sample([0,0,1.7])
        XCTAssertThrowsError(try fuse([p],image:image(actorID:UUID())))
        XCTAssertThrowsError(try fuse([p],image:image(coordinateFrameID:UUID())))
        XCTAssertThrowsError(try fuse([p],owner:UUID()))
        XCTAssertThrowsError(try fuse([p],lidarID:UUID()))
        XCTAssertThrowsError(try fuse([p],image:image(time:1001)))
        XCTAssertThrowsError(try fuse([sample([0,0,1.7],time:1000.02)]))
        XCTAssertThrowsError(try fuse([sample([0,0,1.7],time:1001)]))
        XCTAssertThrowsError(try fuse([sample([0,0,101])]))
        let resized=try FusionCameraFrame(actorID:actor,coordinateFrameID:camera,frameID:UUID(),observedAt:UTCInstant(secondsSince1970:1000),width:4,height:4,rectifiedRGB:Data(repeating:0,count:48))
        XCTAssertThrowsError(try fuse([p],image:resized))
        XCTAssertThrowsError(try fuse([]));XCTAssertThrowsError(try fuse([p,p]))
        XCTAssertThrowsError(try FusionCameraFrame(actorID:actor,coordinateFrameID:camera,frameID:UUID(),observedAt:UTCInstant(secondsSince1970:1000),width:8,height:8,rectifiedRGB:Data()))
        XCTAssertThrowsError(try sample([0,0,1],error:-1))
        XCTAssertThrowsError(try fuse([p],deadline:.now.advanced(by:.seconds(-1))))
    }
    func testOcclusionAndAmbiguousDepthNeverFabricateColors() throws {
        // Camera points (0.125,0.125,2) and (0.25,0.25,4) share pixel (4,4).
        let near=try sample([0.225,0.075,1.7]),far=try sample([0.35,-0.05,3.7])
        let result=try fuse([far,near]);XCTAssertEqual(result.points.map(\.colorState),[.occluded,.fused])
        XCTAssertNil(result.points[0].rgb);XCTAssertNotNil(result.points[1].rgb)
        let ambiguous=try fuse([near,sample([0.225,0.075,1.701])])
        XCTAssertTrue(ambiguous.points.allSatisfy { $0.colorState == .ambiguousDepth && $0.rgb == nil })
        let reverse=try fuse([near,far]);XCTAssertEqual(reverse.points.map(\.colorState),[.fused,.occluded])
    }
    func testOutOfViewAndUncertaintyAreExplicitAndMetricPointsSurvive() throws {
        let outside=try sample([0,-20,1.7]),behind=try sample([0,0,-2]),good=try sample([-0.275,0.575,1.7])
        let result=try fuse([outside,behind,good])
        XCTAssertEqual(result.points.map(\.colorState),[.outsideImage,.behindCamera,.fused])
        // Projection exactly at a half-pixel boundary is not a certain color.
        let uncertain=try fuse([good,sample([0.1,0.2,1.7])])
        XCTAssertTrue(uncertain.points.allSatisfy { $0.rgb == nil && $0.colorState == .uncertainProjection })
        XCTAssertEqual(uncertain.points.count,2)
        let synchronized=try fuse([sample([-0.275,0.575,1.7],time:1000)])
        XCTAssertGreaterThan(result.points[2].maximumErrorMeters,synchronized.points[0].maximumErrorMeters)
    }
    func testCancellationReturnsNoPartialMap() async throws {
        let engine=try CameraLidarFusion(calibration:rig(),maximumTimestampSkewSeconds:0.01,maximumSceneSpeedMetersPerSecond:1)
        let image=try image(),points=try (0..<10000).map { _ in try sample([-0.275,0.575,1.7]) },owner=actor,frame=lidar
        let task=Task { while !Task.isCancelled { await Task.yield() };return try engine.fuse(camera:image,lidarActorID:owner,lidarCoordinateFrameID:frame,lidarFrameID:UUID(),points:points,deadline:.now.advanced(by:.seconds(5))) }
        task.cancel()
        do { _ = try await task.value;XCTFail("Cancelled task returned a map") } catch { XCTAssertTrue(error is CancellationError || error as? FusionError == .cancelled) }
    }
}
