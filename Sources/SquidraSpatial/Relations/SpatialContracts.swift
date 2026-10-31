import Foundation
import SquidraDomain

public enum SpatialValidationError: Error, Equatable, Sendable { case invalidGeometry, invalidPolicy, invalidProvenance, invalidValidity }
public enum SpatialUpAxis: CaseIterable, Sendable {
    case positiveX, negativeX, positiveY, negativeY, positiveZ, negativeZ
    internal var index: Int { switch self { case .positiveX,.negativeX:0;case .positiveY,.negativeY:1;case .positiveZ,.negativeZ:2 } }
    internal var sign: Double { switch self { case .positiveX,.positiveY,.positiveZ:1;case .negativeX,.negativeY,.negativeZ: -1 } }
}
/// Metres in one axis-aligned 3D frame; no transform, depth estimation or sensor calibration occurs here.
public struct SpatialBox3D: Equatable, Sendable {
    public let lower: [Double], upper: [Double], maximumErrorMeters: Double
    public init(lower: [Double], upper: [Double], maximumErrorMeters: Double) throws {
        guard lower.count == 3,upper.count == 3,lower.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
              upper.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
              zip(lower,upper).allSatisfy({ $1-$0 >= 0.000_001 }),maximumErrorMeters.isFinite,(0...10).contains(maximumErrorMeters) else { throw SpatialValidationError.invalidGeometry }
        self.lower = lower;self.upper = upper;self.maximumErrorMeters = maximumErrorMeters
    }
}
public struct SpatialCalibration: Equatable, Sendable {
    public let id: UUID, version: String, maximumErrorMeters: Double
    public init(id: UUID, version: String, maximumErrorMeters: Double) throws {
        guard SpatialSource.validLabel(version),maximumErrorMeters.isFinite,(0...10).contains(maximumErrorMeters) else { throw SpatialValidationError.invalidProvenance }
        self.id = id;self.version = version;self.maximumErrorMeters = maximumErrorMeters
    }
}
public struct SpatialCoordinateFrame: Equatable, Sendable {
    public let actorID: UUID, id: UUID, up: SpatialUpAxis, calibration: SpatialCalibration?
    public init(actorID: UUID, id: UUID, up: SpatialUpAxis, calibration: SpatialCalibration?) {
        self.actorID = actorID;self.id = id;self.up = up;self.calibration = calibration
    }
}
public struct SpatialValidity: Equatable, Sendable {
    public let from: UTCInstant, to: UTCInstant?
    public init(from: UTCInstant, to: UTCInstant?) throws {
        guard to.map({ $0 > from }) ?? true else { throw SpatialValidationError.invalidValidity }
        self.from = from;self.to = to
    }
    internal func intersection(_ other: Self) -> Self? {
        let start = max(from,other.from),end = [to,other.to].compactMap { $0 }.min()
        return try? Self(from:start,to:end)
    }
}
public struct SpatialSource: Equatable, Sendable {
    public let observationID: UUID, cameraID: UUID, imageFrameID: UUID
    public let modelID: String, modelVersion: String
    public let times: ObservationTimestamps
    public let confidence: Confidence?
    public init(observationID: UUID, cameraID: UUID, imageFrameID: UUID, modelID: String, modelVersion: String,
                times: ObservationTimestamps, confidence: Confidence?) throws {
        guard Self.validLabel(modelID),Self.validLabel(modelVersion) else { throw SpatialValidationError.invalidProvenance }
        self.observationID = observationID;self.cameraID = cameraID;self.imageFrameID = imageFrameID
        self.modelID = modelID;self.modelVersion = modelVersion;self.times = times;self.confidence = confidence
    }
    internal static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
    }
}
public enum SpatialGeometry: Equatable, Sendable { case missingDepth, uncalibrated2D, calibrated3D(SpatialBox3D) }
public enum SpatialAssociation: Equatable, Sendable { case confirmed, candidate }
public struct SpatialObservation: Equatable, Sendable {
    public let actorID: UUID, entityID: UUID, coordinateFrameID: UUID?
    public let geometry: SpatialGeometry, association: SpatialAssociation, validity: SpatialValidity, source: SpatialSource
    public init(actorID: UUID, entityID: UUID, coordinateFrameID: UUID?, geometry: SpatialGeometry,
                association: SpatialAssociation, validity: SpatialValidity, source: SpatialSource) {
        self.actorID = actorID;self.entityID = entityID;self.coordinateFrameID = coordinateFrameID;self.geometry = geometry
        self.association = association;self.validity = validity;self.source = source
    }
}
public struct SpatialRelationPolicy: Equatable, Sendable {
    public let id: UUID
    public let nextToMaximumGapMeters: Double, contactToleranceMeters: Double, containmentMarginMeters: Double
    public let minimumFootprintOverlap: Double, minimumVerticalOverlap: Double
    public init(id: UUID, nextToMaximumGapMeters: Double = 0.25, contactToleranceMeters: Double = 0.01,
                containmentMarginMeters: Double = 0.001, minimumFootprintOverlap: Double = 0.5, minimumVerticalOverlap: Double = 0.5) throws {
        let values = [nextToMaximumGapMeters,contactToleranceMeters,containmentMarginMeters,minimumFootprintOverlap,minimumVerticalOverlap]
        guard values.allSatisfy(\.isFinite),(0.001...100).contains(nextToMaximumGapMeters),
              (0.000_001...1).contains(contactToleranceMeters),(0...1).contains(containmentMarginMeters),
              (0.1...1).contains(minimumFootprintOverlap),(0.1...1).contains(minimumVerticalOverlap) else { throw SpatialValidationError.invalidPolicy }
        self.id = id;self.nextToMaximumGapMeters = nextToMaximumGapMeters;self.contactToleranceMeters = contactToleranceMeters
        self.containmentMarginMeters = containmentMarginMeters;self.minimumFootprintOverlap = minimumFootprintOverlap;self.minimumVerticalOverlap = minimumVerticalOverlap
    }
}
public enum SpatialPredicate: String, Equatable, Sendable { case nextTo = "next_to", onTopOf = "on_top_of", inside }
public struct InferredSpatialRelation: Equatable, Sendable {
    public let actorID: UUID, subjectID: UUID, objectID: UUID, coordinateFrameID: UUID
    public let predicate: SpatialPredicate, validity: SpatialValidity, confidence: Confidence?
    public let subjectSource: SpatialSource, objectSource: SpatialSource, calibration: SpatialCalibration, policy: SpatialRelationPolicy
    public let basis = "inferred"
    public let ruleVersion = "calibrated-aabb-1"
    // Only the evaluator constructs inferred relations; evidence never becomes a GroundedAnswer/dispatch grant.
    internal init(actorID: UUID, subject: SpatialObservation, object: SpatialObservation, frame: SpatialCoordinateFrame,
                  calibration: SpatialCalibration, policy: SpatialRelationPolicy, predicate: SpatialPredicate, validity: SpatialValidity, confidence: Confidence?) {
        self.actorID = actorID;subjectID = subject.entityID;objectID = object.entityID;coordinateFrameID = frame.id
        self.predicate = predicate;self.validity = validity;self.confidence = confidence
        subjectSource = subject.source;objectSource = object.source;self.calibration = calibration;self.policy = policy
    }
}
public enum SpatialAbstention: Equatable, Sendable {
    case scopeMismatch, missingFrame, missingCalibration, missingDepth, uncalibrated2D, ambiguousAssociation, sameEntity, disjointValidity, noConservativeRule
}
public struct SpatialRelationResult: Equatable, Sendable {
    public let relations: [InferredSpatialRelation]
    public let abstention: SpatialAbstention?
    internal init(_ relations: [InferredSpatialRelation], _ abstention: SpatialAbstention? = nil) { self.relations = relations;self.abstention = abstention }
}
