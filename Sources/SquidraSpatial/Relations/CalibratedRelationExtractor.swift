import Foundation
import SquidraDomain

/// Pure, constant-size evaluation of one ordered pair. No 2D-to-depth conversion,
/// coordinate transform, identity association, world write or model call.
public struct CalibratedRelationExtractor: Sendable {
    public let actorID: UUID, policy: SpatialRelationPolicy
    public init(actorID: UUID, policy: SpatialRelationPolicy) { self.actorID = actorID;self.policy = policy }
    public func evaluate(subject: SpatialObservation, object: SpatialObservation, frame: SpatialCoordinateFrame?) -> SpatialRelationResult {
        guard subject.actorID == actorID,object.actorID == actorID,frame.map({ $0.actorID == actorID }) ?? true else { return SpatialRelationResult([],.scopeMismatch) }
        guard let frame,let subjectFrame = subject.coordinateFrameID,let objectFrame = object.coordinateFrameID else { return SpatialRelationResult([],.missingFrame) }
        guard frame.id == subjectFrame,frame.id == objectFrame else { return SpatialRelationResult([],.scopeMismatch) }
        guard let calibration = frame.calibration else { return SpatialRelationResult([],.missingCalibration) }
        guard subject.entityID != object.entityID else { return SpatialRelationResult([],.sameEntity) }
        guard subject.association == .confirmed,object.association == .confirmed else { return SpatialRelationResult([],.ambiguousAssociation) }
        guard let validity = subject.validity.intersection(object.validity) else { return SpatialRelationResult([],.disjointValidity) }
        if subject.geometry == .uncalibrated2D || object.geometry == .uncalibrated2D { return SpatialRelationResult([],.uncalibrated2D) }
        guard case .calibrated3D(let a) = subject.geometry,case .calibrated3D(let b) = object.geometry else { return SpatialRelationResult([],.missingDepth) }
        // One nanometre also conservatively covers arithmetic at the bounded
        // ±1,000,000 m coordinate magnitude. Threshold equality does not erase uncertainty.
        let ea = a.maximumErrorMeters+calibration.maximumErrorMeters+0.000_000_001
        let eb = b.maximumErrorMeters+calibration.maximumErrorMeters+0.000_000_001
        let up = frame.up.index,horizontal = (0..<3).filter { $0 != up }
        func lower(_ box:SpatialBox3D) -> Double { frame.up.sign > 0 ? box.lower[up] : -box.upper[up] }
        func upper(_ box:SpatialBox3D) -> Double { frame.up.sign > 0 ? box.upper[up] : -box.lower[up] }
        func guaranteedOverlap(_ axis:Int) -> Double { max(0,min(a.upper[axis]-ea,b.upper[axis]-eb)-max(a.lower[axis]+ea,b.lower[axis]+eb)) }
        var predicates:[SpatialPredicate] = []
        let inside = (0..<3).allSatisfy { axis in
            a.lower[axis]-ea >= b.lower[axis]+eb+policy.containmentMarginMeters && a.upper[axis]+ea <= b.upper[axis]-eb-policy.containmentMarginMeters
        }
        if inside { predicates.append(.inside) }
        let gap = lower(a)-upper(b),gapError = ea+eb
        let footprint = horizontal.reduce(1.0) { $0*guaranteedOverlap($1) }
        let subjectFootprint = horizontal.reduce(1.0) { $0*(a.upper[$1]-a.lower[$1]+2*ea) }
        if gap-gapError >= -policy.contactToleranceMeters,gap+gapError <= policy.contactToleranceMeters,
           lower(a)-ea > (lower(b)+upper(b))/2+eb,
           footprint/subjectFootprint >= policy.minimumFootprintOverlap { predicates.append(.onTopOf) }
        let vertical = guaranteedOverlap(up),subjectHeight = a.upper[up]-a.lower[up]+2*ea,objectHeight = b.upper[up]-b.lower[up]+2*eb
        // Worst-case horizontal AABB separation, not a centre/mask distance.
        var minimumGapSquared = 0.0,maximumGapSquared = 0.0
        for axis in horizontal {
            let measured = max(a.lower[axis]-b.upper[axis],b.lower[axis]-a.upper[axis])
            let minimum = max(0,measured-gapError),maximum = max(0,measured+gapError)
            minimumGapSquared += minimum*minimum;maximumGapSquared += maximum*maximum
        }
        if minimumGapSquared > 0,maximumGapSquared.squareRoot() <= policy.nextToMaximumGapMeters,
           vertical/max(subjectHeight,objectHeight) >= policy.minimumVerticalOverlap { predicates.append(.nextTo) }
        let confidence:Confidence?
        if let ac = subject.source.confidence,let bc = object.source.confidence { confidence = try? Confidence(min(ac.value,bc.value)) }
        else { confidence = nil }
        let relations = predicates.map { InferredSpatialRelation(actorID:actorID,subject:subject,object:object,frame:frame,
            calibration:calibration,policy:policy,predicate:$0,validity:validity,confidence:confidence) }
        return SpatialRelationResult(relations,relations.isEmpty ? .noConservativeRule : nil)
    }
}
