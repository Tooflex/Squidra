import Crypto
import Foundation
import SquidraDomain
import SquidraSpatial

public enum MovementError: Error, Equatable, Sendable {
    case invalidPolicy, invalidHistory, scopeMismatch, capacityExceeded, conflictingObservation, cancelled
}
public struct MovementThreshold: Equatable, Sendable {
    public let minimumDisplacementMeters: Double, destinationToleranceMeters: Double
    public let confirmations: Int
    public let minimumDurationSeconds: Double, maximumGapSeconds: Double
    public init(minimumDisplacementMeters: Double, destinationToleranceMeters: Double = 0.03,
                confirmations: Int = 3, minimumDurationSeconds: Double = 0.2, maximumGapSeconds: Double = 2) throws {
        guard minimumDisplacementMeters.isFinite, (0.001...1000).contains(minimumDisplacementMeters),
              destinationToleranceMeters.isFinite, (0.000001...100).contains(destinationToleranceMeters),
              destinationToleranceMeters < minimumDisplacementMeters, (2...16).contains(confirmations),
              minimumDurationSeconds.isFinite, (0.001...60).contains(minimumDurationSeconds),
              maximumGapSeconds.isFinite, (0.001...3600).contains(maximumGapSeconds)
        else { throw MovementError.invalidPolicy }
        self.minimumDisplacementMeters = minimumDisplacementMeters; self.destinationToleranceMeters = destinationToleranceMeters
        self.confirmations = confirmations; self.minimumDurationSeconds = minimumDurationSeconds; self.maximumGapSeconds = maximumGapSeconds
    }
}
public struct MovementPolicy: Equatable, Sendable {
    public let id: UUID, thresholdsByType: [String: MovementThreshold]
    public init(id: UUID, thresholdsByType: [String: MovementThreshold]) throws {
        guard (1...32).contains(thresholdsByType.count), thresholdsByType.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 && $0.utf8.allSatisfy { (33...126).contains($0) } })
        else { throw MovementError.invalidPolicy }
        self.id = id; self.thresholdsByType = thresholdsByType
    }
}
/// An absent observation is an explicit occlusion; no position is extrapolated.
public struct MovementSample: Equatable, Sendable {
    public let observedAt: UTCInstant
    public let observation: SpatialObservation?
    public let frame: SpatialCoordinateFrame?
    public init(observedAt: UTCInstant, observation: SpatialObservation?, frame: SpatialCoordinateFrame?) {
        self.observedAt = observedAt; self.observation = observation; self.frame = frame
    }
}
public enum MovementAbstention: String, Sendable {
    case occluded, unqualifiedEvidence, coordinateChanged, gap, contradiction, uncertainDestination, insufficientRepetition
}
public struct MovementDecision: Sendable {
    public let sampleIndex: Int, reason: MovementAbstention
}
public struct ConfirmedMovement: Sendable {
    /// Stable SHA-256 over epoch, policy, entity and ordered supporting IDs.
    public let id: String
    public let actorID: UUID, entityID: UUID, epochID: UUID
    public let entityType: String, frame: SpatialCoordinateFrame, policy: MovementPolicy
    public let baseline: SpatialObservation, confirmations: [SpatialObservation]
    public let minimumDisplacementMeters: Double
    public let basis = "inferred"
    public let ruleVersion = "confirmed-centre-displacement-1"
}
public struct MovementReport: Sendable {
    /// Complete unchanged input, including contradictory and missing evidence.
    public let samples: [MovementSample]
    public let events: [ConfirmedMovement]
    public let abstentions: [MovementDecision]
}

/// Deterministic replay of one bounded, complete actor/entity epoch. This does
/// not claim physical tracking through an occlusion or durable delivery. Hosts
/// must retain epoch boundaries and deduplicate event IDs when publishing.
public struct ConfirmedMovementDetector: Sendable {
    public let actorID: UUID, entityID: UUID, epochID: UUID, entityType: String, policy: MovementPolicy
    public init(actorID: UUID, entityID: UUID, epochID: UUID, entityType: String, policy: MovementPolicy) throws {
        guard policy.thresholdsByType[entityType] != nil else { throw MovementError.invalidPolicy }
        self.actorID = actorID; self.entityID = entityID; self.epochID = epochID; self.entityType = entityType; self.policy = policy
    }
    public func evaluate(_ samples: [MovementSample]) throws -> MovementReport {
        guard samples.count <= 1024 else { throw MovementError.capacityExceeded }
        let threshold = policy.thresholdsByType[entityType]!
        var seen: [UUID: MovementSample] = [:], unique: [(Int,MovementSample)] = []
        var imageFrames: Set<UUID> = []
        var previousTime: UTCInstant?
        for (index,sample) in samples.enumerated() {
            guard !Task.isCancelled else { throw MovementError.cancelled }
            guard previousTime.map({ sample.observedAt >= $0 }) ?? true else { throw MovementError.invalidHistory }
            previousTime = sample.observedAt
            if let observation = sample.observation {
                guard observation.actorID == actorID, observation.entityID == entityID,
                      sample.frame.map({ $0.actorID == actorID }) ?? true else { throw MovementError.scopeMismatch }
                guard observation.source.times.observedAt == sample.observedAt,
                      observation.validity.from <= sample.observedAt,
                      observation.validity.to.map({ sample.observedAt < $0 }) ?? true else { throw MovementError.invalidHistory }
                if let old = seen[observation.source.observationID] {
                    guard old == sample else { throw MovementError.conflictingObservation }
                    continue
                }
                guard imageFrames.insert(observation.source.imageFrameID).inserted else { throw MovementError.conflictingObservation }
                seen[observation.source.observationID] = sample
            }
            unique.append((index,sample))
        }
        var baseline: MovementSample?, pending: [MovementSample] = [], last: MovementSample?
        var events: [ConfirmedMovement] = [], decisions: [MovementDecision] = []
        var cursor = 0
        while cursor < unique.count {
            guard !Task.isCancelled else { throw MovementError.cancelled }
            let (index,sample) = unique[cursor]
            var end = cursor+1
            while end < unique.count && unique[end].1.observedAt == sample.observedAt { end += 1 }
            if end > cursor+1 {
                // Simultaneous alternatives are retained, never resolved by input order.
                for item in unique[cursor..<end] { decisions.append(MovementDecision(sampleIndex: item.0,reason: .contradiction)) }
                baseline = nil; pending = []; last = nil; cursor = end; continue
            }
            cursor = end
            guard let observation = sample.observation else {
                decisions.append(MovementDecision(sampleIndex: index,reason: .occluded)); baseline = nil; pending = []; last = nil; continue
            }
            guard observation.association == .confirmed, case .calibrated3D = observation.geometry,
                  let frame = sample.frame, frame.calibration != nil, observation.coordinateFrameID == frame.id else {
                decisions.append(MovementDecision(sampleIndex: index,reason: .unqualifiedEvidence)); baseline = nil; pending = []; last = nil; continue
            }
            if let old = last {
                let oldSource = old.observation!.source
                if old.frame != frame || oldSource.cameraID != observation.source.cameraID || oldSource.modelID != observation.source.modelID || oldSource.modelVersion != observation.source.modelVersion {
                    decisions.append(MovementDecision(sampleIndex: index,reason: .coordinateChanged)); baseline = nil; pending = []
                } else if sample.observedAt.secondsSince1970-old.observedAt.secondsSince1970 > threshold.maximumGapSeconds {
                    decisions.append(MovementDecision(sampleIndex: index,reason: .gap)); baseline = nil; pending = []
                }
            }
            last = sample
            guard let origin = baseline else { baseline = sample; continue }
            let distance = Self.distance(origin,sample)
            guard distance.minimum > threshold.minimumDisplacementMeters else { pending = []; continue }
            // Every repeated destination must be mutually consistent; one
            // contradictory alternative cannot be hidden by averaging positions.
            if pending.contains(where: { Self.distance($0,sample).maximum > threshold.destinationToleranceMeters }) {
                decisions.append(MovementDecision(sampleIndex: index,reason: .uncertainDestination)); pending = []
            }
            pending.append(sample)
            // Bounded evidence window; duration is evaluated over the same samples.
            if pending.count > 16 { pending.removeFirst() }
            guard pending.count >= threshold.confirmations,
                  sample.observedAt.secondsSince1970-pending[0].observedAt.secondsSince1970 >= threshold.minimumDurationSeconds else {
                decisions.append(MovementDecision(sampleIndex: index,reason: .insufficientRepetition)); continue
            }
            let confirmations = pending.map { $0.observation! }
            let sourceIDs = [origin.observation!.source.observationID]+confirmations.map { $0.source.observationID }
            let atoms = ["confirmed-centre-displacement-1",actorID.uuidString,entityID.uuidString,epochID.uuidString,entityType,policy.id.uuidString,
                String(threshold.minimumDisplacementMeters.bitPattern),String(threshold.destinationToleranceMeters.bitPattern),String(threshold.confirmations),
                String(threshold.minimumDurationSeconds.bitPattern),String(threshold.maximumGapSeconds.bitPattern)] + sourceIDs.map(\.uuidString)
            let bytes = Data(atoms.map { "\($0.utf8.count):\($0)" }.joined().utf8)
            let id = SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined()
            events.append(ConfirmedMovement(id: id,actorID: actorID,entityID: entityID,epochID: epochID,entityType: entityType,frame: frame,
                policy: policy,baseline: origin.observation!,confirmations: confirmations,
                minimumDisplacementMeters: pending.map { Self.distance(origin,$0).minimum }.min()!))
            baseline = sample; pending = []
        }
        return MovementReport(samples: samples,events: events,abstentions: decisions)
    }
    private static func distance(_ a: MovementSample, _ b: MovementSample) -> (minimum: Double,maximum: Double) {
        guard case .calibrated3D(let x) = a.observation!.geometry, case .calibrated3D(let y) = b.observation!.geometry else { preconditionFailure("qualified samples only") }
        let error = x.maximumErrorMeters+y.maximumErrorMeters+a.frame!.calibration!.maximumErrorMeters+b.frame!.calibration!.maximumErrorMeters+0.000000002
        var lower = 0.0,upper = 0.0
        for axis in 0..<3 {
            let delta = abs((x.lower[axis]+x.upper[axis])/2-(y.lower[axis]+y.upper[axis])/2)
            lower += pow(max(0,delta-error),2); upper += pow(delta+error,2)
        }
        return (sqrt(lower),sqrt(upper))
    }
}
