import Crypto
import Foundation
import SquidraDomain

/// No provider-local ID, label or nearest-neighbor iteration order determines
/// entity identity. Matches must be unique in both directions with a margin.
public struct ContinuityEntityResolver: EntityResolver {
    private let store: any EntityAssociationStore
    public let policy: AssociationPolicy
    public init(store: any EntityAssociationStore, policy: AssociationPolicy) { self.store = store; self.policy = policy }
    public func resolve(_ frame: ImportedFrame, deadline: ContinuousClock.Instant) async throws -> EntityResolution {
        let deadline = min(deadline, .now.advanced(by: .seconds(5)))
        try Self.check(deadline)
        do {
            return try await withThrowingTaskGroup(of: EntityResolution.self) { group in
                group.addTask { try await resolveBounded(frame, deadline: deadline) }
                group.addTask { try await ContinuousClock().sleep(until: deadline); throw EntityAssociationError.timeout }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw EntityAssociationError.unavailable }; return result
            }
        } catch is CancellationError { throw Task.isCancelled ? EntityAssociationError.cancelled : EntityAssociationError.timeout }
        catch let error as EntityAssociationError { throw error }
        catch { throw EntityAssociationError.unavailable }
    }
    private func resolveBounded(_ frame: ImportedFrame, deadline: ContinuousClock.Instant) async throws -> EntityResolution {
        let context = frame.context, observedAt = context.timestamps.observedAt
        let previous = try await store.load(actorID: context.actorID, cameraID: context.cameraID, deadline: deadline)
        try Self.check(deadline)
        let digest = Self.digest(frame)
        if let previous {
            let old = previous.resolution
            guard old.context.actorID == context.actorID, old.context.cameraID == context.cameraID, previous.policy == policy else { throw EntityAssociationError.invalidState }
            if old.context.frameID == context.frameID {
                guard previous.inputDigest == digest else { throw EntityAssociationError.idempotencyConflict }
                return old
            }
            guard old.identity == frame.identity, previous.width == frame.width, previous.height == frame.height else { throw EntityAssociationError.incompatibleFrame }
            guard old.context.timestamps.observedAt < observedAt else { throw EntityAssociationError.outOfOrder }
            guard previous.revision < Int64.max else { throw EntityAssociationError.capacityExceeded }
        }
        var tracks = previous?.tracks.filter { observedAt.secondsSince1970 - $0.lastSeen.secondsSince1970 <= policy.maximumGapSeconds } ?? []
        // Sort solely for stable reporting. Ties still fail the ambiguity margin.
        tracks.sort { $0.entityID.uuidString < $1.entityID.uuidString }
        var scores: [[AssociationCandidate]] = []
        for detection in frame.detections {
            try Self.check(deadline)
            let ranked = try tracks.compactMap { track -> AssociationCandidate? in
                guard let appearance = Self.cosine(detection.appearance, track.appearance) else { return nil }
                let a = detection.box, b = track.box
                let dx = Double(a.x) + Double(a.width)/2 - Double(b.x) - Double(b.width)/2
                let dy = Double(a.y) + Double(a.height)/2 - Double(b.y) - Double(b.height)/2
                let diagonal = hypot(Double(frame.width), Double(frame.height))
                let continuity = max(0, 1 - hypot(dx,dy)/diagonal)
                return try AssociationCandidate(entityID: track.entityID, score: min(1, appearance*policy.appearanceWeight + continuity*(1-policy.appearanceWeight)))
            }.sorted { $0.score == $1.score ? $0.entityID.uuidString < $1.entityID.uuidString : $0.score > $1.score }
            scores.append(ranked)
        }
        var assignments: [EntityAssignment] = []
        for (index, detection) in frame.detections.enumerated() {
            try Self.check(deadline)
            let candidates = scores[index], best = candidates.first
            var match = false
            if let best, best.score >= policy.threshold {
                let ownMargin = candidates.count < 2 || best.score - candidates[1].score >= policy.ambiguityMargin
                let competitors = scores.enumerated().filter { $0.offset != index }.compactMap { $0.element.first(where: { $0.entityID == best.entityID })?.score }
                let mutualMargin = competitors.max().map { best.score - $0 >= policy.ambiguityMargin } ?? true
                match = ownMargin && mutualMargin
            }
            let kind: EntityAssignmentKind = match ? .matched : (best.map { $0.score >= policy.threshold } ?? false) ? .ambiguousCandidate : .newCandidate
            var entityID = match ? best!.entityID : UUID()
            // UUID collision is not a reason to merge two objects.
            for _ in 0..<8 where !match && tracks.contains(where: { $0.entityID == entityID }) { entityID = UUID() }
            guard match || !tracks.contains(where: { $0.entityID == entityID }) else { throw EntityAssociationError.capacityExceeded }
            let track = try EntityTrack(entityID: entityID, lastSeen: observedAt, box: detection.box, appearance: detection.appearance)
            if let i = tracks.firstIndex(where: { $0.entityID == entityID }) { tracks[i] = track } else { tracks.append(track) }
            assignments.append(try EntityAssignment(localID: detection.localID, entityID: entityID, kind: kind, candidates: candidates))
        }
        guard tracks.count <= policy.maximumTracks else { throw EntityAssociationError.capacityExceeded }
        let resolution = try EntityResolution(context: context, identity: frame.identity, imageSHA256: frame.imageSHA256, assignments: assignments)
        let state = try EntityAssociationState(revision: (previous?.revision ?? 0)+1, policy: policy,
            width: frame.width, height: frame.height, inputDigest: digest, resolution: resolution, tracks: tracks)
        try Self.check(deadline)
        try await store.compareAndSwap(state, expectedRevision: previous?.revision, deadline: deadline)
        // If cancellation/timeout races a committed CAS, report it; a retry loads
        // the saved frame digest instead of inventing a second set of identities.
        try Self.check(deadline)
        return resolution
    }
    private static func cosine(_ a: [Double]?, _ b: [Double]?) -> Double? {
        guard let a, let b, a.count == b.count else { return nil }
        let aa = a.reduce(0) { $0+$1*$1 }, bb = b.reduce(0) { $0+$1*$1 }
        guard aa > 1e-12, bb > 1e-12 else { return nil }
        return min(1,max(0,zip(a,b).reduce(0) { $0+$1.0*$1.1 } / sqrt(aa*bb)))
    }
    private static func check(_ deadline: ContinuousClock.Instant) throws {
        guard !Task.isCancelled else { throw EntityAssociationError.cancelled }
        guard deadline > .now else { throw EntityAssociationError.timeout }
    }
    /// Length-prefixed UTF-8 atoms; exact normalized values, including mask and
    /// floating-point bits. This is internal replay identity, not a wire digest.
    private static func digest(_ frame: ImportedFrame) -> String {
        var bytes = Data()
        func add(_ value: String) { bytes.append(contentsOf: "\(value.utf8.count):".utf8); bytes.append(contentsOf: value.utf8) }
        let context = frame.context, times = context.timestamps
        for value in ["1",context.actorID.uuidString,context.cameraID.uuidString,context.frameID.uuidString,
                      times.occurredAt.map { String($0.secondsSince1970.bitPattern,radix:16) } ?? "nil",
                      String(times.observedAt.secondsSince1970.bitPattern,radix:16),String(times.recordedAt.secondsSince1970.bitPattern,radix:16),times.timeZone.identifier,
                      frame.identity.modelID,frame.identity.version,frame.identity.deployment.rawValue,frame.imageSHA256,String(frame.width),String(frame.height),String(frame.detections.count)] { add(value) }
        for detection in frame.detections {
            let box = detection.box
            for value in [detection.localID,detection.label,String(box.x),String(box.y),String(box.width),String(box.height),
                          String(detection.mask.width),String(detection.mask.height),SHA256.hash(data:detection.mask.pixels).map { String(format:"%02x",$0) }.joined(),
                          detection.confidence.map { String($0.value.bitPattern,radix:16) } ?? "nil",String(detection.appearance?.count ?? -1)] { add(value) }
            for value in detection.appearance ?? [] { add(String(value.bitPattern,radix:16)) }
        }
        return SHA256.hash(data: bytes).map { String(format:"%02x",$0) }.joined()
    }
}
