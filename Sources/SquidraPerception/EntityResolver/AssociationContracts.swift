import Foundation
import SquidraDomain

public enum EntityAssociationError: Error, Equatable, Sendable {
    case invalidState, incompatibleFrame, outOfOrder, idempotencyConflict, capacityExceeded, conflict, unavailable, timeout, cancelled
}
/// Scores are configurable heuristics, not calibrated identity probabilities.
public struct AssociationPolicy: Equatable, Sendable {
    public let threshold: Double, ambiguityMargin: Double, appearanceWeight: Double
    public let maximumGapSeconds: Double
    public let maximumTracks: Int
    public init(threshold: Double = 0.8, ambiguityMargin: Double = 0.05, appearanceWeight: Double = 0.85,
                maximumGapSeconds: Double = 30, maximumTracks: Int = 256) throws {
        guard threshold.isFinite, (0.5...1).contains(threshold), ambiguityMargin.isFinite, (0.001...0.5).contains(ambiguityMargin),
              appearanceWeight.isFinite, (0.5...1).contains(appearanceWeight),
              maximumGapSeconds.isFinite, (0.001...3600).contains(maximumGapSeconds), (1...256).contains(maximumTracks)
        else { throw EntityAssociationError.invalidState }
        self.threshold = threshold; self.ambiguityMargin = ambiguityMargin; self.appearanceWeight = appearanceWeight
        self.maximumGapSeconds = maximumGapSeconds; self.maximumTracks = maximumTracks
    }
}
public struct EntityTrack: Equatable, Sendable {
    public let entityID: UUID
    public let lastSeen: UTCInstant
    public let box: PixelBox
    public let appearance: [Double]?
    public init(entityID: UUID, lastSeen: UTCInstant, box: PixelBox, appearance: [Double]?) throws {
        guard appearance.map({ !$0.isEmpty && $0.count <= 256 && $0.allSatisfy { $0.isFinite && (-1...1).contains($0) } }) ?? true
        else { throw EntityAssociationError.invalidState }
        self.entityID = entityID; self.lastSeen = lastSeen; self.box = box; self.appearance = appearance
    }
}
public struct AssociationCandidate: Equatable, Sendable {
    public let entityID: UUID
    public let score: Double
    public init(entityID: UUID, score: Double) throws {
        guard score.isFinite, (0...1).contains(score) else { throw EntityAssociationError.invalidState }
        self.entityID = entityID; self.score = score
    }
}
public enum EntityAssignmentKind: String, Sendable { case matched, newCandidate, ambiguousCandidate }
public struct EntityAssignment: Equatable, Sendable {
    public let localID: String
    public let entityID: UUID
    public let kind: EntityAssignmentKind
    /// At most 256 ranked candidates, never truncated to manufacture uniqueness.
    public let candidates: [AssociationCandidate]
    public var score: Double? { candidates.first?.score }
    public init(localID: String, entityID: UUID, kind: EntityAssignmentKind, candidates: [AssociationCandidate]) throws {
        guard !localID.isEmpty, localID.utf8.count <= 64, candidates.count <= 256,
              Set(candidates.map(\.entityID)).count == candidates.count,
              zip(candidates, candidates.dropFirst()).allSatisfy({ $0.0.score >= $0.1.score }),
              kind != .matched || candidates.first?.entityID == entityID,
              kind == .matched || !candidates.contains(where: { $0.entityID == entityID }) else { throw EntityAssociationError.invalidState }
        self.localID = localID; self.entityID = entityID; self.kind = kind; self.candidates = candidates
    }
}
public struct EntityResolution: Equatable, Sendable {
    public let context: FrameContext
    public let identity: VisionIdentity
    public let imageSHA256: String
    public let assignments: [EntityAssignment]
    public var synthetic: Bool { identity.deployment == .synthetic }
    public init(context: FrameContext, identity: VisionIdentity, imageSHA256: String, assignments: [EntityAssignment]) throws {
        guard imageSHA256.utf8.count == 64, imageSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              assignments.count <= 128, Set(assignments.map(\.localID)).count == assignments.count,
              Set(assignments.map(\.entityID)).count == assignments.count else { throw EntityAssociationError.invalidState }
        self.context = context; self.identity = identity; self.imageSHA256 = imageSHA256; self.assignments = assignments
    }
}
/// Actor/camera association cache. This is not an immutable world journal.
public struct EntityAssociationState: Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: Int64
    public let policy: AssociationPolicy
    public let width: Int, height: Int
    public let inputDigest: String
    public let resolution: EntityResolution
    public let tracks: [EntityTrack]
    public init(schemaVersion: Int = 1, revision: Int64, policy: AssociationPolicy, width: Int, height: Int,
                inputDigest: String, resolution: EntityResolution, tracks: [EntityTrack]) throws {
        guard schemaVersion == 1, revision > 0, (1...2048).contains(width), (1...2048).contains(height),
              inputDigest.utf8.count == 64, inputDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              tracks.count <= policy.maximumTracks, Set(tracks.map(\.entityID)).count == tracks.count,
              tracks.allSatisfy({ $0.lastSeen <= resolution.context.timestamps.observedAt && resolution.context.timestamps.observedAt.secondsSince1970 - $0.lastSeen.secondsSince1970 <= policy.maximumGapSeconds && $0.box.x + $0.box.width <= width && $0.box.y + $0.box.height <= height }),
              resolution.assignments.allSatisfy({ assignment in tracks.contains { $0.entityID == assignment.entityID && $0.lastSeen == resolution.context.timestamps.observedAt } })
        else { throw EntityAssociationError.invalidState }
        let known = Set(tracks.map(\.entityID))
        for assignment in resolution.assignments {
            guard assignment.candidates.allSatisfy({ known.contains($0.entityID) }) else { throw EntityAssociationError.invalidState }
            let best = assignment.candidates.first
            let thresholdMet = best.map { $0.score >= policy.threshold } ?? false
            let ownMargin = assignment.candidates.count < 2 || best!.score - assignment.candidates[1].score >= policy.ambiguityMargin
            let mutualMargin = best.map { best in
                resolution.assignments.filter { $0.localID != assignment.localID }.allSatisfy { other in
                    other.candidates.first(where: { $0.entityID == best.entityID }).map { best.score - $0.score >= policy.ambiguityMargin } ?? true
                }
            } ?? false
            switch assignment.kind {
            case .matched: guard thresholdMet && ownMargin && mutualMargin else { throw EntityAssociationError.invalidState }
            case .newCandidate: guard !thresholdMet else { throw EntityAssociationError.invalidState }
            case .ambiguousCandidate: guard thresholdMet && !(ownMargin && mutualMargin) else { throw EntityAssociationError.invalidState }
            }
        }
        self.schemaVersion = schemaVersion; self.revision = revision; self.policy = policy
        self.width = width; self.height = height; self.inputDigest = inputDigest; self.resolution = resolution; self.tracks = tracks
    }
}
/// Implementations must bind actor/camera on load and CAS, honor cancellation
/// and deadline, and persist the entire state atomically. nil revision means
/// create-only; conflicts must not overwrite a winning state. Ambiguous writes
/// throw unavailable; callers reload using last-frame idempotency before retry.
public protocol EntityAssociationStore: Sendable {
    func load(actorID: UUID, cameraID: UUID, deadline: ContinuousClock.Instant) async throws -> EntityAssociationState?
    func compareAndSwap(_ state: EntityAssociationState, expectedRevision: Int64?, deadline: ContinuousClock.Instant) async throws
}
public protocol EntityResolver: Sendable {
    func resolve(_ frame: ImportedFrame, deadline: ContinuousClock.Instant) async throws -> EntityResolution
}
