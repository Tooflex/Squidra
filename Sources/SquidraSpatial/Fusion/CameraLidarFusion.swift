import Foundation
import SquidraDomain

public enum FusionColorState: String, Sendable, Encodable { case fused, outsideImage, behindCamera, uncertainProjection, occluded, ambiguousDepth }
public struct FusionMapPoint: Sendable, Encodable {
    public let id: UUID, position: FusionPoint, observedAt: String, maximumErrorMeters: Double
    public let pixelX: Int?, pixelY: Int?, rgb: [UInt8]?, colorState: FusionColorState
}
public struct FusionMetricMap: Sendable, Encodable {
    public let timeZone = "Etc/UTC"
    public let actorID: UUID, coordinateFrameID: UUID, cameraFrameID: UUID, lidarFrameID: UUID, calibrationID: UUID
    public let cameraCoordinateFrameID: UUID, lidarCoordinateFrameID: UUID
    public let calibrationVersion: String, cameraObservedAt: String, maximumSceneSpeedMetersPerSecond: Double
    public let maximumTimestampSkewSeconds: Double, processingNanoseconds: Double
    public let points: [FusionMapPoint]
}

public struct CameraLidarFusion: Sendable {
    public let calibration: FusionCalibration, maximumTimestampSkewSeconds: Double, maximumSceneSpeedMetersPerSecond: Double
    public init(calibration: FusionCalibration, maximumTimestampSkewSeconds: Double, maximumSceneSpeedMetersPerSecond: Double) throws {
        guard maximumTimestampSkewSeconds.isFinite,(0...1).contains(maximumTimestampSkewSeconds),
              maximumSceneSpeedMetersPerSecond.isFinite,(0...1000).contains(maximumSceneSpeedMetersPerSecond) else { throw FusionError.invalidNumber }
        self.calibration=calibration;self.maximumTimestampSkewSeconds=maximumTimestampSkewSeconds;self.maximumSceneSpeedMetersPerSecond=maximumSceneSpeedMetersPerSecond
    }
    private struct Candidate {
        let input: FusionLidarPoint, position: FusionPoint, error: Double, camera: FusionPoint, cameraError: Double
        var pixel: Int?, color: FusionColorState
    }
    /// Bounded single synchronized capture. Colors are nearest-pixel samples only
    /// when the complete projected uncertainty interval lies inside that pixel.
    public func fuse(camera: FusionCameraFrame, lidarActorID: UUID, lidarCoordinateFrameID: UUID, lidarFrameID: UUID,
                     points: [FusionLidarPoint], deadline: ContinuousClock.Instant) throws -> FusionMetricMap {
        let start=ContinuousClock.now,c=calibration,k=c.intrinsics
        func check() throws {
            if Task.isCancelled { throw FusionError.cancelled }
            guard ContinuousClock.now < deadline else { throw FusionError.bounds }
        }
        try check()
        guard camera.actorID == c.actorID,lidarActorID == c.actorID,camera.coordinateFrameID == c.lidarToCamera.to,lidarCoordinateFrameID == c.lidarToCamera.from else { throw FusionError.scopeMismatch }
        guard camera.width == k.width,camera.height == k.height,(1...100_000).contains(points.count),Set(points.map(\.id)).count == points.count else { throw FusionError.bounds }
        guard camera.observedAt >= c.validFrom,camera.observedAt < c.validUntil else { throw FusionError.expiredCalibration }
        var candidates: [Candidate]=[],pixels:[Int:[Int]]=[:],skew=0.0
        candidates.reserveCapacity(points.count)
        for p in points {
            try check()
            guard p.observedAt >= c.validFrom,p.observedAt < c.validUntil else { throw FusionError.expiredCalibration }
            let delta=abs(p.observedAt.secondsSince1970-camera.observedAt.secondsSince1970)
            guard delta <= maximumTimestampSkewSeconds else { throw FusionError.timestampMismatch }
            guard p.position.norm+p.maximumErrorMeters*sqrt(3) <= c.maximumRangeMeters else { throw FusionError.bounds }
            skew=max(skew,delta)
            let cp=try c.lidarToCamera.apply(p.position)
            let temporalError=maximumSceneSpeedMetersPerSecond*delta
            let ce=c.lidarToCamera.propagatedError(p.maximumErrorMeters)+temporalError
            guard cp.norm+ce*sqrt(3) <= c.maximumRangeMeters else { throw FusionError.bounds }
            let mp=try c.cameraToMap.apply(cp),me=c.cameraToMap.propagatedError(ce)
            var candidate=Candidate(input:p,position:mp,error:me,camera:cp,cameraError:ce,pixel:nil,color:.behindCamera)
            if cp.z > ce {
                let (u,v)=k.project(cp)!
                if u >= -0.5,u < Double(k.width)-0.5,v >= -0.5,v < Double(k.height)-0.5 {
                    let x=Int(floor(u+0.5)),y=Int(floor(v+0.5))
                    // Bound the division using all interval corners, including sign changes.
                    func bounds(_ value: Double, focal: Double, centre: Double) -> (Double,Double) {
                        let ratios=[(value-ce)/(cp.z-ce),(value-ce)/(cp.z+ce),(value+ce)/(cp.z-ce),(value+ce)/(cp.z+ce)]
                        return (focal*ratios.min()!+centre-k.maximumPixelError,focal*ratios.max()!+centre+k.maximumPixelError)
                    }
                    let ub=bounds(cp.x,focal:k.fx,centre:k.cx),vb=bounds(cp.y,focal:k.fy,centre:k.cy)
                    if ub.0 > Double(x)-0.5,ub.1 < Double(x)+0.5,vb.0 > Double(y)-0.5,vb.1 < Double(y)+0.5 {
                        candidate.pixel=y*k.width+x;candidate.color = .fused
                    } else { candidate.color = .uncertainProjection }
                } else {
                    // A nominally off-screen sample can still cross the image edge.
                    let uError=k.fx*(ce/(cp.z-ce)+abs(cp.x)*ce/(cp.z*(cp.z-ce)))+k.maximumPixelError
                    let vError=k.fy*(ce/(cp.z-ce)+abs(cp.y)*ce/(cp.z*(cp.z-ce)))+k.maximumPixelError
                    candidate.color = u+uError >= -0.5 && u-uError < Double(k.width)-0.5 && v+vError >= -0.5 && v-vError < Double(k.height)-0.5 ? .uncertainProjection : .outsideImage
                }
            } else if cp.z+ce > 0 { candidate.color = .uncertainProjection }
            if let pixel=candidate.pixel { pixels[pixel,default:[]].append(candidates.count) }
            candidates.append(candidate)
        }
        // Visibility only among supplied LiDAR samples; unseen camera occluders
        // cannot be certified away by this registration algorithm.
        for indices in pixels.values where indices.count > 1 {
            try check()
            var nearest=indices[0]
            for index in indices.dropFirst() { try check();if candidates[index].camera.z < candidates[nearest].camera.z { nearest=index } }
            let first=candidates[nearest],upper=first.camera.z+first.cameraError
            var ambiguous=false
            for index in indices where index != nearest {
                try check()
                if candidates[index].camera.z-candidates[index].cameraError <= upper { ambiguous=true }
            }
            for index in indices { try check();candidates[index].color = ambiguous ? .ambiguousDepth : index == nearest ? .fused : .occluded }
        }
        // Without a bounded visibility footprint for an uncertain projection,
        // conservatively abstain from all color assignments in this capture.
        // Metric positions and their error bounds remain usable.
        if candidates.contains(where:{ $0.color == .uncertainProjection }) {
            for index in candidates.indices where candidates[index].color == .fused { candidates[index].color = .uncertainProjection }
        }
        var output:[FusionMapPoint]=[];output.reserveCapacity(candidates.count)
        for p in candidates {
            try check()
            let color=p.color == .fused ? p.pixel.map { Array(camera.rgb[($0*3)..<($0*3+3)]) } : nil
            output.append(FusionMapPoint(id:p.input.id,position:p.position,observedAt:try RFC3339.format(p.input.observedAt),maximumErrorMeters:p.error,
                pixelX:p.pixel.map { $0%k.width },pixelY:p.pixel.map { $0/k.width },rgb:color,colorState:p.color))
        }
        try check()
        let elapsed=start.duration(to:.now).components
        return FusionMetricMap(actorID:c.actorID,coordinateFrameID:c.cameraToMap.to,cameraFrameID:camera.frameID,lidarFrameID:lidarFrameID,
            calibrationID:c.id,cameraCoordinateFrameID:c.lidarToCamera.to,lidarCoordinateFrameID:c.lidarToCamera.from,calibrationVersion:c.version,cameraObservedAt:try RFC3339.format(camera.observedAt),maximumSceneSpeedMetersPerSecond:maximumSceneSpeedMetersPerSecond,
            maximumTimestampSkewSeconds:skew,processingNanoseconds:Double(elapsed.seconds)*1e9+Double(elapsed.attoseconds)/1e9,points:output)
    }
}
