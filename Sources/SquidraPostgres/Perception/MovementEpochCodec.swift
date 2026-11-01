import Foundation
import SquidraDomain
import SquidraPerception
import SquidraSpatial

internal enum MovementEpochCodec {
    static let maximumBytes = 2_097_152
    private struct Threshold: Codable { let displacement: String, tolerance: String, duration: String, gap: String; let count: Int }
    private struct Frame: Codable { let actor: UUID, id: UUID, up: Int; let calibration: UUID?, version: String?, error: String? }
    private struct Observation: Codable {
        let actor: UUID, entity: UUID, frame: UUID?, association: String, geometry: String
        let lower: [String]?, upper: [String]?, error: String?, from: String, to: String?
        let observation: UUID, camera: UUID, image: UUID, model: String, version: String
        let occurred: String?, observed: String, recorded: String, zone: String, confidence: String?
    }
    private struct Sample: Codable { let time: String, observation: Observation?, frame: Frame? }
    private struct Wire: Codable {
        let version: Int, actor: UUID, entity: UUID, epoch: UUID, type: String, origin: String, policy: UUID
        let thresholds: [String: Threshold], samples: [Sample]
    }
    private static func bits(_ x: Double) -> String { String(x.bitPattern,radix: 16) }
    private static func number(_ s: String) throws -> Double {
        guard s.count <= 16,let raw = UInt64(s,radix: 16),Double(bitPattern: raw).isFinite else { throw MovementEpochError.invalidState }
        return Double(bitPattern: raw)
    }
    static func encode(_ epoch: MovementEpoch) throws -> String {
        let d = epoch.detector
        let thresholds = d.policy.thresholdsByType.mapValues { Threshold(displacement: bits($0.minimumDisplacementMeters),tolerance: bits($0.destinationToleranceMeters),duration: bits($0.minimumDurationSeconds),gap: bits($0.maximumGapSeconds),count: $0.confirmations) }
        let samples = epoch.samples.map { sample -> Sample in
            let frame = sample.frame.map { Frame(actor: $0.actorID,id: $0.id,up: SpatialUpAxis.allCases.firstIndex(of: $0.up)!,calibration: $0.calibration?.id,version: $0.calibration?.version,error: $0.calibration.map { bits($0.maximumErrorMeters) }) }
            let observation = sample.observation.map { o -> Observation in
                let kind: String,lower: [String]?,upper: [String]?,error: String?
                switch o.geometry {
                case .missingDepth: kind = "missing"; lower = nil; upper = nil; error = nil
                case .uncalibrated2D: kind = "2d"; lower = nil; upper = nil; error = nil
                case .calibrated3D(let box): kind = "3d"; lower = box.lower.map(bits); upper = box.upper.map(bits); error = bits(box.maximumErrorMeters)
                }
                let s = o.source,t = s.times
                return Observation(actor: o.actorID,entity: o.entityID,frame: o.coordinateFrameID,association: o.association == .confirmed ? "confirmed" : "candidate",geometry: kind,
                    lower: lower,upper: upper,error: error,from: bits(o.validity.from.secondsSince1970),to: o.validity.to.map { bits($0.secondsSince1970) },
                    observation: s.observationID,camera: s.cameraID,image: s.imageFrameID,model: s.modelID,version: s.modelVersion,
                    occurred: t.occurredAt.map { bits($0.secondsSince1970) },observed: bits(t.observedAt.secondsSince1970),recorded: bits(t.recordedAt.secondsSince1970),zone: t.timeZone.identifier,confidence: s.confidence.map { bits($0.value) })
            }
            return Sample(time: bits(sample.observedAt.secondsSince1970),observation: observation,frame: frame)
        }
        let wire = Wire(version: 1,actor: d.actorID,entity: d.entityID,epoch: d.epochID,type: d.entityType,origin: epoch.origin.rawValue,policy: d.policy.id,thresholds: thresholds,samples: samples)
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let data = try encoder.encode(wire)
        guard data.count <= maximumBytes else { throw MovementEpochError.invalidState }
        return String(decoding: data,as: UTF8.self)
    }
    static func decode(_ text: String) throws -> MovementEpoch {
        do {
            guard text.utf8.count <= maximumBytes else { throw MovementEpochError.invalidState }
            let data = Data(text.utf8),w = try JSONDecoder().decode(Wire.self,from: data)
            guard w.version == 1,w.samples.count <= 1024,w.thresholds.count <= 32,let origin = MovementEvidenceOrigin(rawValue: w.origin) else { throw MovementEpochError.invalidState }
            let thresholds = try w.thresholds.mapValues { try MovementThreshold(minimumDisplacementMeters: number($0.displacement),destinationToleranceMeters: number($0.tolerance),confirmations: $0.count,minimumDurationSeconds: number($0.duration),maximumGapSeconds: number($0.gap)) }
            let samples = try w.samples.map { s -> MovementSample in
                let frame = try s.frame.map { f -> SpatialCoordinateFrame in
                    guard SpatialUpAxis.allCases.indices.contains(f.up) else { throw MovementEpochError.invalidState }
                    let calibration: SpatialCalibration?
                    if let id = f.calibration,let version = f.version,let error = f.error { calibration = try SpatialCalibration(id: id,version: version,maximumErrorMeters: number(error)) }
                    else { guard f.calibration == nil,f.version == nil,f.error == nil else { throw MovementEpochError.invalidState };calibration = nil }
                    return SpatialCoordinateFrame(actorID: f.actor,id: f.id,up: SpatialUpAxis.allCases[f.up],calibration: calibration)
                }
                let observation = try s.observation.map { o -> SpatialObservation in
                    let geometry: SpatialGeometry
                    switch o.geometry {
                    case "missing": geometry = .missingDepth
                    case "2d": geometry = .uncalibrated2D
                    case "3d": guard let lower = o.lower,let upper = o.upper,let error = o.error else { throw MovementEpochError.invalidState };geometry = try .calibrated3D(SpatialBox3D(lower: lower.map(number),upper: upper.map(number),maximumErrorMeters: number(error)))
                    default: throw MovementEpochError.invalidState
                    }
                    guard ["confirmed","candidate"].contains(o.association) else { throw MovementEpochError.invalidState }
                    let times = try ObservationTimestamps(occurredAt: o.occurred.map { try UTCInstant(secondsSince1970: number($0)) },observedAt: UTCInstant(secondsSince1970: number(o.observed)),recordedAt: UTCInstant(secondsSince1970: number(o.recorded)),timeZone: IANATimeZone(identifier: o.zone))
                    return try SpatialObservation(actorID: o.actor,entityID: o.entity,coordinateFrameID: o.frame,geometry: geometry,association: o.association == "confirmed" ? .confirmed : .candidate,
                        validity: SpatialValidity(from: UTCInstant(secondsSince1970: number(o.from)),to: o.to.map { try UTCInstant(secondsSince1970: number($0)) }),
                        source: SpatialSource(observationID: o.observation,cameraID: o.camera,imageFrameID: o.image,modelID: o.model,modelVersion: o.version,times: times,confidence: o.confidence.map { try Confidence(number($0)) }))
                }
                return try MovementSample(observedAt: UTCInstant(secondsSince1970: number(s.time)),observation: observation,frame: frame)
            }
            let epoch = try MovementEpoch(detector: ConfirmedMovementDetector(actorID: w.actor,entityID: w.entity,epochID: w.epoch,entityType: w.type,policy: MovementPolicy(id: w.policy,thresholdsByType: thresholds)),samples: samples,origin: origin)
            let canonical = try encode(epoch)
            guard (try JSONSerialization.jsonObject(with: data) as? NSDictionary) == (try JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? NSDictionary) else { throw MovementEpochError.invalidState }
            return epoch
        } catch { throw MovementEpochError.invalidState }
    }
}
