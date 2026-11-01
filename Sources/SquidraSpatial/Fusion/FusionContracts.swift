import Foundation
import SquidraDomain

public enum FusionError: Error, Equatable { case invalidNumber, invalidRotation, invalidCalibration, scopeMismatch, expiredCalibration, timestampMismatch, bounds, cancelled }

/// Right-handed Cartesian metres. No implicit axis or unit conversion.
public struct FusionPoint: Sendable, Equatable, Encodable {
    public let x: Double, y: Double, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) throws {
        guard [x,y,z].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { throw FusionError.invalidNumber }
        self.x=x;self.y=y;self.z=z
    }
    var values: [Double] { [x,y,z] }
    var norm: Double { sqrt(x*x+y*y+z*z) }
}

public struct FusionTransform: Sendable {
    public let from: UUID, to: UUID, rotation: [Double], translation: FusionPoint
    /// Conservative coordinate-wise transform error over the rig's bounded input domain.
    public let maximumErrorMeters: Double
    public init(from: UUID, to: UUID, rotation: [Double], translation: FusionPoint, maximumErrorMeters: Double) throws {
        guard from != to,rotation.count == 9,rotation.allSatisfy(\.isFinite),
              maximumErrorMeters.isFinite,(0...10).contains(maximumErrorMeters) else { throw FusionError.invalidCalibration }
        for row in 0..<3 { for other in 0..<3 {
            let dot=(0..<3).reduce(0.0) { $0+rotation[row*3+$1]*rotation[other*3+$1] }
            guard abs(dot-(row == other ? 1 : 0)) <= 1e-9 else { throw FusionError.invalidRotation }
        } }
        let r=rotation,det=r[0]*(r[4]*r[8]-r[5]*r[7])-r[1]*(r[3]*r[8]-r[5]*r[6])+r[2]*(r[3]*r[7]-r[4]*r[6])
        guard abs(det-1) <= 1e-9 else { throw FusionError.invalidRotation }
        self.from=from;self.to=to;self.rotation=rotation;self.translation=translation;self.maximumErrorMeters=maximumErrorMeters
    }
    public func apply(_ point: FusionPoint) throws -> FusionPoint {
        let p=point.values,t=translation.values
        let v=(0..<3).map { row in (0..<3).reduce(t[row]) { $0+rotation[row*3+$1]*p[$1] } }
        return try FusionPoint(v[0],v[1],v[2])
    }
    func propagatedError(_ error: Double) -> Double {
        (0..<3).map { row in (0..<3).reduce(0.0) { $0+abs(rotation[row*3+$1]) } }.max()!*error+maximumErrorMeters+1e-9
    }
}

/// Rectified pinhole image: +X right, +Y down, +Z forward; integer pixel centres.
public struct FusionIntrinsics: Sendable {
    public let width: Int, height: Int
    public let fx: Double, fy: Double, cx: Double, cy: Double, maximumPixelError: Double
    public init(width: Int, height: Int, fx: Double, fy: Double, cx: Double, cy: Double, maximumPixelError: Double) throws {
        guard (1...1024).contains(width),(1...1024).contains(height),[fx,fy,cx,cy,maximumPixelError].allSatisfy(\.isFinite),
              fx > 0,fy > 0,fx <= 100_000,fy <= 100_000,cx >= 0,cx < Double(width),cy >= 0,cy < Double(height),
              (0...10).contains(maximumPixelError) else { throw FusionError.invalidCalibration }
        self.width=width;self.height=height;self.fx=fx;self.fy=fy;self.cx=cx;self.cy=cy;self.maximumPixelError=maximumPixelError
    }
    func project(_ p: FusionPoint) -> (Double,Double)? {
        guard p.z > 0 else { return nil };return (fx*p.x/p.z+cx,fy*p.y/p.z+cy)
    }
}

public struct FusionCalibrationCheck: Sendable {
    public let lidar: FusionPoint, map: FusionPoint, u: Double, v: Double
    public init(lidar: FusionPoint, map: FusionPoint, u: Double, v: Double) throws {
        guard u.isFinite,v.isFinite else { throw FusionError.invalidNumber }
        self.lidar=lidar;self.map=map;self.u=u;self.v=v
    }
}

/// Validation checks consistency against host-supplied surveyed correspondences;
/// it does not discover calibration or certify a physical sensor.
public struct FusionCalibration: Sendable {
    public let actorID: UUID, id: UUID, version: String, intrinsics: FusionIntrinsics
    public let lidarToCamera: FusionTransform, cameraToMap: FusionTransform
    public let validFrom: UTCInstant, validUntil: UTCInstant, maximumRangeMeters: Double
    public let validationMaximumMetricError: Double, validationMaximumPixelError: Double
    public init(actorID: UUID, id: UUID, version: String, intrinsics: FusionIntrinsics,
                lidarToCamera: FusionTransform, cameraToMap: FusionTransform, validFrom: UTCInstant, validUntil: UTCInstant,
                maximumRangeMeters: Double, checks: [FusionCalibrationCheck], metricTolerance: Double, pixelTolerance: Double) throws {
        guard !version.isEmpty,version.utf8.count <= 128,!version.contains("\0"),
              lidarToCamera.to == cameraToMap.from,Set([lidarToCamera.from,lidarToCamera.to,cameraToMap.to]).count == 3,
              [maximumRangeMeters,metricTolerance,pixelTolerance].allSatisfy(\.isFinite),
              validFrom < validUntil,(0.001...1000).contains(maximumRangeMeters),(0...1).contains(metricTolerance),(0...10).contains(pixelTolerance),
              (4...64).contains(checks.count) else { throw FusionError.invalidCalibration }
        // Reject collinear/coplanar support: a fixture must constrain three axes.
        let origin=checks[0].lidar.values
        let vectors=checks.dropFirst().map { c in zip(c.lidar.values,origin).map(-) }
        var volume=0.0
        for a in vectors.indices { for b in vectors.indices where b > a { for c in vectors.indices where c > b {
            let x=vectors[a],y=vectors[b],z=vectors[c]
            volume=max(volume,abs(x[0]*(y[1]*z[2]-y[2]*z[1])-x[1]*(y[0]*z[2]-y[2]*z[0])+x[2]*(y[0]*z[1]-y[1]*z[0])))
        } } }
        guard volume > 1e-9 else { throw FusionError.invalidCalibration }
        var metric=0.0,pixels=0.0
        for check in checks {
            guard check.lidar.norm <= maximumRangeMeters else { throw FusionError.bounds }
            let camera=try lidarToCamera.apply(check.lidar),map=try cameraToMap.apply(camera)
            guard let (u,v)=intrinsics.project(camera),camera.norm <= maximumRangeMeters,check.u >= 0,check.v >= 0,check.u < Double(intrinsics.width),check.v < Double(intrinsics.height) else { throw FusionError.invalidCalibration }
            metric=max(metric,zip(map.values,check.map.values).map { abs($0-$1) }.max()!)
            pixels=max(pixels,abs(u-check.u),abs(v-check.v))
        }
        guard metricTolerance <= cameraToMap.propagatedError(lidarToCamera.maximumErrorMeters),pixelTolerance <= intrinsics.maximumPixelError,metric <= metricTolerance,pixels <= pixelTolerance else { throw FusionError.invalidCalibration }
        self.actorID=actorID;self.id=id;self.version=version;self.intrinsics=intrinsics;self.lidarToCamera=lidarToCamera;self.cameraToMap=cameraToMap
        self.validFrom=validFrom;self.validUntil=validUntil;self.maximumRangeMeters=maximumRangeMeters
        validationMaximumMetricError=metric;validationMaximumPixelError=pixels
    }
}

public struct FusionCameraFrame: Sendable {
    public let actorID: UUID, coordinateFrameID: UUID, frameID: UUID, observedAt: UTCInstant, width: Int, height: Int, rgb: Data
    public init(actorID: UUID, coordinateFrameID: UUID, frameID: UUID, observedAt: UTCInstant, width: Int, height: Int, rectifiedRGB: Data) throws {
        guard (1...1024).contains(width),(1...1024).contains(height),rectifiedRGB.count == width*height*3 else { throw FusionError.bounds }
        self.actorID=actorID;self.coordinateFrameID=coordinateFrameID;self.frameID=frameID;self.observedAt=observedAt;self.width=width;self.height=height;rgb=rectifiedRGB
    }
}
public struct FusionLidarPoint: Sendable {
    public let id: UUID, position: FusionPoint, observedAt: UTCInstant, maximumErrorMeters: Double
    public init(id: UUID, position: FusionPoint, observedAt: UTCInstant, maximumErrorMeters: Double) throws {
        guard maximumErrorMeters.isFinite,(0...10).contains(maximumErrorMeters) else { throw FusionError.invalidNumber }
        self.id=id;self.position=position;self.observedAt=observedAt;self.maximumErrorMeters=maximumErrorMeters
    }
}
