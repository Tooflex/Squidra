import Foundation
import SquidraDomain
import SquidraSpatial

public enum SceneRelationError: Error, Equatable, Sendable {
    case incompatibleEvidence, capacityExceeded, cancelled
}

/// Host-supplied depth evidence for one detection. Never derived from a 2D mask.
public struct DetectionSpatialEvidence: Sendable {
    public let localID: String, observationID: UUID
    public let geometry: SpatialGeometry, validity: SpatialValidity
    public init(localID: String, observationID: UUID, geometry: SpatialGeometry, validity: SpatialValidity) {
        self.localID = localID; self.observationID = observationID
        self.geometry = geometry; self.validity = validity
    }
}

public struct SceneRelationPair: Sendable {
    public let subjectLocalID: String, objectLocalID: String
    public let result: SpatialRelationResult
}

/// Keeps the original resolution (including synthetic provenance and association
/// scores), calibrated observations, and every evaluated ordered pair together.
public struct ResolvedSceneRelations: Sendable {
    public let resolution: EntityResolution
    public let observations: [SpatialObservation]
    public let pairs: [SceneRelationPair]
    public var relations: [InferredSpatialRelation] { pairs.flatMap { $0.result.relations } }
}

public struct SceneRelationExtractor: Sendable {
    public let actorID: UUID, policy: SpatialRelationPolicy
    public init(actorID: UUID, policy: SpatialRelationPolicy) { self.actorID = actorID; self.policy = policy }

    /// At most 32 detections / 992 ordered pairs; rejects oversized scenes rather
    /// than selecting a misleading subset. Evidence must cover the exact imported
    /// frame. Candidate identities remain candidates even with excellent geometry.
    public func evaluate(frame: ImportedFrame, resolution: EntityResolution,
                         evidenceContext: FrameContext, evidence: [DetectionSpatialEvidence],
                         coordinateFrame: SpatialCoordinateFrame?) throws -> ResolvedSceneRelations {
        guard !Task.isCancelled else { throw SceneRelationError.cancelled }
        guard frame.detections.count <= 32, evidence.count <= 32 else { throw SceneRelationError.capacityExceeded }
        let localIDs = Set(frame.detections.map(\.localID))
        guard frame.context.actorID == actorID, resolution.context == frame.context,
              evidenceContext == frame.context, resolution.identity == frame.identity,
              resolution.imageSHA256 == frame.imageSHA256,
              Set(resolution.assignments.map(\.localID)) == localIDs,
              Set(evidence.map(\.localID)) == localIDs, evidence.count == localIDs.count,
              Set(evidence.map(\.observationID)).count == evidence.count,
              coordinateFrame.map({ $0.actorID == actorID }) ?? true,
              evidence.allSatisfy({ $0.validity.from <= frame.context.timestamps.observedAt &&
                  ($0.validity.to.map { frame.context.timestamps.observedAt < $0 } ?? true) })
        else { throw SceneRelationError.incompatibleEvidence }
        let assignments = Dictionary(uniqueKeysWithValues: resolution.assignments.map { ($0.localID,$0) })
        let geometry = Dictionary(uniqueKeysWithValues: evidence.map { ($0.localID,$0) })
        let observations = try frame.detections.map { detection in
            let assignment = assignments[detection.localID]!, item = geometry[detection.localID]!
            return SpatialObservation(actorID: actorID, entityID: assignment.entityID,
                coordinateFrameID: coordinateFrame?.id, geometry: item.geometry,
                association: assignment.kind == .matched ? .confirmed : .candidate, validity: item.validity,
                source: try SpatialSource(observationID: item.observationID, cameraID: frame.context.cameraID,
                    imageFrameID: frame.context.frameID, modelID: frame.identity.modelID, modelVersion: frame.identity.version,
                    times: frame.context.timestamps, confidence: detection.confidence))
        }
        let extractor = CalibratedRelationExtractor(actorID: actorID, policy: policy)
        var pairs: [SceneRelationPair] = []
        for i in observations.indices {
            guard !Task.isCancelled else { throw SceneRelationError.cancelled }
            for j in observations.indices where i != j {
                pairs.append(SceneRelationPair(subjectLocalID: frame.detections[i].localID,
                    objectLocalID: frame.detections[j].localID,
                    result: extractor.evaluate(subject: observations[i], object: observations[j], frame: coordinateFrame)))
            }
        }
        return ResolvedSceneRelations(resolution: resolution, observations: observations, pairs: pairs)
    }
}
