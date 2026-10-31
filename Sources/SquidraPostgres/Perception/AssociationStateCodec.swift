import Foundation
import SquidraDomain
import SquidraPerception

/// Versioned cache encoding. Compact vectors/candidates keep the full 32-track
/// profile inside JSONDocument's existing byte/node limits, without truncation.
internal enum AssociationStateCodec {
    static let maximumTracks = 32
    static let maximumBytes = 262_144
    private struct Policy: Codable { let threshold: String, margin: String, weight: String, gap: String; let tracks: Int }
    private struct Assignment: Codable { let localID: String, entityID: String, kind: String; let candidates: [String] }
    private struct Track: Codable { let entityID: String, seen: String; let box: [Int]; let appearance: String? }
    private struct Wire: Codable {
        let schemaVersion: Int
        let revision: String
        let policy: Policy
        let width: Int, height: Int
        let inputDigest: String
        let actorID: String, cameraID: String, frameID: String
        let occurred: String?, observed: String, recorded: String, timeZone: String
        let modelID: String, modelVersion: String, deployment: String, imageSHA256: String
        let assignments: [Assignment]
        let tracks: [Track]
    }
    private static func bits(_ value: Double) -> String { String(value.bitPattern,radix:16) }
    private static func number(_ value: String) throws -> Double {
        guard !value.isEmpty, value.utf8.count <= 16, let bits = UInt64(value,radix:16), Double(bitPattern:bits).isFinite else { throw EntityAssociationError.invalidState }
        return Double(bitPattern:bits)
    }
    private static func uuid(_ value: String) throws -> UUID {
        guard let result = UUID(uuidString:value) else { throw EntityAssociationError.invalidState }; return result
    }
    static func encode(_ state: EntityAssociationState) throws -> String {
        guard state.policy.maximumTracks <= maximumTracks, state.tracks.count <= maximumTracks else { throw EntityAssociationError.capacityExceeded }
        let r = state.resolution, c = r.context, t = c.timestamps, p = state.policy
        let wire = Wire(schemaVersion:state.schemaVersion,revision:String(state.revision),
            policy:Policy(threshold:bits(p.threshold),margin:bits(p.ambiguityMargin),weight:bits(p.appearanceWeight),gap:bits(p.maximumGapSeconds),tracks:p.maximumTracks),
            width:state.width,height:state.height,inputDigest:state.inputDigest,
            actorID:c.actorID.uuidString.lowercased(),cameraID:c.cameraID.uuidString.lowercased(),frameID:c.frameID.uuidString.lowercased(),
            occurred:t.occurredAt.map { bits($0.secondsSince1970) },observed:bits(t.observedAt.secondsSince1970),recorded:bits(t.recordedAt.secondsSince1970),timeZone:t.timeZone.identifier,
            modelID:r.identity.modelID,modelVersion:r.identity.version,deployment:r.identity.deployment.rawValue,imageSHA256:r.imageSHA256,
            assignments:r.assignments.map { a in Assignment(localID:a.localID,entityID:a.entityID.uuidString.lowercased(),kind:a.kind.rawValue,
                candidates:a.candidates.map { $0.entityID.uuidString.lowercased()+":"+bits($0.score) }) },
            tracks:state.tracks.map { track in Track(entityID:track.entityID.uuidString.lowercased(),seen:bits(track.lastSeen.secondsSince1970),
                box:[track.box.x,track.box.y,track.box.width,track.box.height],appearance:track.appearance.map { $0.map(bits).joined(separator:":") }) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let data = try encoder.encode(wire)
        do { _ = try JSONDocument(data,maximumBytes:maximumBytes) } catch { throw EntityAssociationError.capacityExceeded }
        return String(decoding:data,as:UTF8.self)
    }
    static func decode(_ text: String) throws -> EntityAssociationState {
        do {
            let data = Data(text.utf8); _ = try JSONDocument(data,maximumBytes:maximumBytes)
            let wire = try JSONDecoder().decode(Wire.self,from:data)
            guard wire.schemaVersion == 1, let revision = Int64(wire.revision),
                  wire.tracks.count <= maximumTracks, wire.assignments.count <= maximumTracks,
                  wire.policy.tracks <= maximumTracks, let deployment = VisionDeployment(rawValue:wire.deployment) else { throw EntityAssociationError.invalidState }
            let policy = try AssociationPolicy(threshold:number(wire.policy.threshold),ambiguityMargin:number(wire.policy.margin),appearanceWeight:number(wire.policy.weight),maximumGapSeconds:number(wire.policy.gap),maximumTracks:wire.policy.tracks)
            let context = try FrameContext(actorID:uuid(wire.actorID),cameraID:uuid(wire.cameraID),frameID:uuid(wire.frameID),
                timestamps:ObservationTimestamps(occurredAt:wire.occurred.map { try UTCInstant(secondsSince1970:number($0)) },observedAt:UTCInstant(secondsSince1970:number(wire.observed)),recordedAt:UTCInstant(secondsSince1970:number(wire.recorded)),timeZone:IANATimeZone(identifier:wire.timeZone)))
            let identity = try VisionIdentity(modelID:wire.modelID,version:wire.modelVersion,deployment:deployment)
            let assignments = try wire.assignments.map { a in
                guard a.candidates.count <= maximumTracks, let kind = EntityAssignmentKind(rawValue:a.kind) else { throw EntityAssociationError.invalidState }
                return try EntityAssignment(localID:a.localID,entityID:uuid(a.entityID),kind:kind,candidates:a.candidates.map { item in
                    let parts = item.split(separator:":",omittingEmptySubsequences:false)
                    guard parts.count == 2 else { throw EntityAssociationError.invalidState }
                    return try AssociationCandidate(entityID:uuid(String(parts[0])),score:number(String(parts[1])))
                })
            }
            let resolution = try EntityResolution(context:context,identity:identity,imageSHA256:wire.imageSHA256,assignments:assignments)
            let tracks = try wire.tracks.map { t in
                guard t.box.count == 4 else { throw EntityAssociationError.invalidState }
                let appearance = try t.appearance.map { packed in
                    let values = packed.split(separator:":",omittingEmptySubsequences:false)
                    guard values.count <= 256 else { throw EntityAssociationError.invalidState }
                    return try values.map { try number(String($0)) }
                }
                return try EntityTrack(entityID:uuid(t.entityID),lastSeen:UTCInstant(secondsSince1970:number(t.seen)),box:PixelBox(x:t.box[0],y:t.box[1],width:t.box[2],height:t.box[3]),appearance:appearance)
            }
            let state = try EntityAssociationState(schemaVersion:wire.schemaVersion,revision:revision,policy:policy,width:wire.width,height:wire.height,inputDigest:wire.inputDigest,resolution:resolution,tracks:tracks)
            // Reject unknown/missing fields and noncanonical encodings after
            // typed reconstruction. All numeric payloads here are small ints;
            // times/revisions/score bits remain strings with exact precision.
            let canonical = try encode(state)
            guard (try JSONSerialization.jsonObject(with:data) as? NSDictionary) == (try JSONSerialization.jsonObject(with:Data(canonical.utf8)) as? NSDictionary) else { throw EntityAssociationError.invalidState }
            return state
        } catch { throw EntityAssociationError.invalidState }
    }
}
