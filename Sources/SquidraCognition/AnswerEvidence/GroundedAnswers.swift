import Foundation
import SquidraDomain
import SquidraWorld

public enum GroundedAnswerStatus: String, Encodable, Sendable { case grounded, partial, unknown }
public struct GroundedClaimDTO: Encodable, Sendable {
    public let kind: String,subjectId: UUID,locationId: UUID?,frameId: UUID?,changeId: UUID?
    public let basis: String,changeKind: String?,minimumSourceConfidence: Double?,citationIds: [UUID]
}
public struct GroundedAnswer: Encodable, Sendable {
    public let schemaVersion = "1"
    public let actorId: UUID,requestId: UUID,intent: AnswerIntent,status: GroundedAnswerStatus
    public let text: String,claims: [GroundedClaimDTO],evidence: [AnswerEvidenceDTO],uncertainty: [String]
}
public struct GroundedAnswerValidator: Sendable {
    public init() {}
    private struct Proposed: Decodable {
        let kind: String,subjectId: UUID,locationId: UUID?,frameId: UUID?,changeId: UUID?,citations: [UUID]
    }
    private struct Response: Decodable { let schemaVersion: String,claims: [Proposed] }
    public func validate(_ response: ModelResponse, expectedRequestID: UUID, context: AnswerEvidenceContext) throws -> GroundedAnswer {
        guard response.requestID == expectedRequestID else { throw AnswerEvidenceError.requestMismatch }
        guard response.schemaVersion == "1" else { throw AnswerEvidenceError.invalidResponse }
        let proposed = try parse(Data(response.text.utf8))
        let (evidence,now) = try context.refreshed()
        var claims: [GroundedClaimDTO] = [],lines: [String] = [],keys: Set<String> = []
        var unknown: Set<UUID> = [],specified: Set<UUID> = [],frames: Set<UUID> = [],changes: Set<UUID> = []
        for claim in proposed.claims {
            guard claim.citations.count <= 16,Set(claim.citations).count == claim.citations.count else { throw AnswerEvidenceError.invalidCitation }
            guard context.subjects.contains(claim.subjectId) else { throw AnswerEvidenceError.unsupportedClaim }
            let selected = try claim.citations.map { id -> WorldLocationFact in
                guard let fact = context.facts[id],fact.subjectID == claim.subjectId else { throw AnswerEvidenceError.invalidCitation };return fact
            }
            let citations = claim.citations.sorted { $0.uuidString < $1.uuidString }
            let basis = selected.contains(where:{ $0.basis == .inferred }) ? "inferred" : "observed"
            let confidence = selected.map(\.confidence.value).min()
            let citationText = citations.map { $0.uuidString.lowercased() }.joined(separator:", ")
            switch claim.kind {
            case "unknown":
                guard claim.citations.isEmpty,keys.insert("unknown:"+claim.subjectId.uuidString).inserted else { throw AnswerEvidenceError.invalidResponse }
                unknown.insert(claim.subjectId)
                claims.append(GroundedClaimDTO(kind:"unknown",subjectId:claim.subjectId,locationId:nil,frameId:nil,changeId:nil,basis:"unknown",changeKind:nil,minimumSourceConfidence:nil,citationIds:[]))
                lines.append("Unknown location for \(claim.subjectId.uuidString.lowercased()) from the supplied evidence.")
            case "location":
                guard case .state(let snapshot) = context.scope,let location = claim.locationId,let frame = claim.frameId,!selected.isEmpty,
                      selected.allSatisfy({ $0.locationID == location && $0.frameID == frame }),
                      keys.insert("location:"+claim.subjectId.uuidString+":"+frame.uuidString).inserted else { throw AnswerEvidenceError.unsupportedClaim }
                let alternatives = context.facts.values.filter { $0.subjectID == claim.subjectId && $0.frameID == frame }
                guard Set(alternatives.map(\.locationID)).count == 1 else { throw AnswerEvidenceError.conflictingEvidence }
                if context.intent != .historical {
                    guard selected.map(\.timestamps.observedAt).max() == alternatives.map(\.timestamps.observedAt).max() else { throw AnswerEvidenceError.unsupportedClaim }
                }
                if context.intent == .current {
                    guard !context.isPartial else { throw AnswerEvidenceError.incompleteEvidence }
                    let nowMicroseconds = try AnswerEvidenceContext.times(now,now).observedMicroseconds
                    let validAge = now.secondsSince1970-snapshot.validAt.secondsSince1970,knownAge = now.secondsSince1970-snapshot.knownAt.secondsSince1970
                    guard validAge >= 0,knownAge >= 0,validAge <= context.policy.maximumObservationAgeSeconds,knownAge <= context.policy.maximumObservationAgeSeconds,
                          selected.allSatisfy({ AnswerEvidenceContext.contains($0.valid,nowMicroseconds) && AnswerEvidenceContext.contains($0.transaction,nowMicroseconds) && evidence[$0.sourceEventID]?.freshness == .fresh }) else { throw AnswerEvidenceError.staleEvidence }
                    guard selected.allSatisfy({ $0.confidence.value > 0 && $0.confidence.value >= context.policy.minimumCurrentConfidence.value }) else { throw AnswerEvidenceError.insufficientEvidence }
                    guard context.policy.allowInferredCurrent || basis != "inferred" else { throw AnswerEvidenceError.unsupportedClaim }
                }
                frames.insert(frame);specified.insert(claim.subjectId)
                claims.append(GroundedClaimDTO(kind:"location",subjectId:claim.subjectId,locationId:location,frameId:frame,changeId:nil,basis:basis,changeKind:nil,minimumSourceConfidence:confidence,citationIds:citations))
                let observed = try selected.map(\.timestamps.observedAt).max().map(AnswerEvidenceContext.utc) ?? "unknown"
                let ages = citations.compactMap { evidence[$0]?.observationAgeSeconds }
                let age = ages.count == citations.count ? String(format:"%.3f",ages.max() ?? 0)+" seconds" : "unknown (clock skew)"
                lines.append("\(basis.capitalized) location evidence for \(claim.subjectId.uuidString.lowercased()): \(location.uuidString.lowercased()) in frame \(frame.uuidString.lowercased()); minimum source confidence \(String(format:"%.3f",confidence!)), latest cited observation \(observed), oldest cited age \(age). Citations: \(citationText).")
            case "change":
                guard case .changes = context.scope,let id = claim.changeId,let change = context.changes[id],change.current.subjectID == claim.subjectId,
                      Set(citations) == Set(change.supportingEventIDs),keys.insert("change:"+id.uuidString).inserted else { throw AnswerEvidenceError.unsupportedClaim }
                changes.insert(id);specified.insert(claim.subjectId)
                claims.append(GroundedClaimDTO(kind:"change",subjectId:claim.subjectId,locationId:change.current.locationID,frameId:change.current.frameID,changeId:id,
                    basis:basis,changeKind:change.kind.rawValue,minimumSourceConfidence:confidence,citationIds:citations))
                let label: String
                switch change.kind { case .observation:label = "Location observation";case .locationChanged:label = "Supported location-state change";case .correction:label = "Correction of recorded location evidence" }
                lines.append("\(label) for \(claim.subjectId.uuidString.lowercased()) at \(try AnswerEvidenceContext.utc(change.effectiveAt)); \(basis), minimum source confidence \(String(format:"%.3f",confidence!)). Citations: \(citationText).")
            default: throw AnswerEvidenceError.invalidResponse
            }
        }
        guard unknown.isDisjoint(with:specified) else { throw AnswerEvidenceError.unsupportedClaim }
        let covered: Bool
        switch context.scope {
        case .state: covered = Set(context.facts.values.map(\.frameID)).isSubset(of:frames)
        case .changes: covered = Set(context.changes.keys).isSubset(of:changes)
        }
        let status: GroundedAnswerStatus = specified.isEmpty ? .unknown : (context.isPartial || !covered || !unknown.isEmpty ? .partial : .grounded)
        var uncertainty = context.uncertainty
        if evidence.values.contains(where:{ $0.freshness == .stale }) { uncertainty.insert("stale_observation") }
        if evidence.values.contains(where:{ $0.freshness == .clockSkew }) { uncertainty.insert("clock_skew") }
        if status == .unknown { uncertainty.insert("abstained") }
        let header: String
        switch context.scope {
        case .state(let snapshot):
            switch context.intent {
            case .historical:header = "Evidence for valid time \(try AnswerEvidenceContext.utc(snapshot.validAt)), known at \(try AnswerEvidenceContext.utc(snapshot.knownAt))."
            case .latestObservation:header = "Latest supplied observation evidence; this does not establish a current physical position."
            case .current:header = "Recent observation evidence for the current query; continuous position is not confirmed."
            }
        case .changes(let query):header = "Recorded location-state evidence for [\(try AnswerEvidenceContext.utc(query.window.from)), \(try AnswerEvidenceContext.utc(query.window.to!))), known at \(try AnswerEvidenceContext.utc(query.knownAt))."
        }
        if lines.isEmpty { lines = ["No supported conclusion was selected from the supplied evidence."] }
        if context.isPartial || !covered { lines.append("Evidence coverage is incomplete.") }
        if uncertainty.contains("conflictingLocations") { lines.append("Conflicting observations remain unresolved.") }
        return GroundedAnswer(actorId:context.actorID,requestId:expectedRequestID,intent:context.intent,status:status,text:([header]+lines).joined(separator:"\n"),claims:claims,
            evidence:evidence.values.sorted { $0.id.uuidString < $1.id.uuidString },uncertainty:uncertainty.sorted())
    }
    private func parse(_ data: Data) throws -> Response {
        do {
            let document = try JSONDocument(data,maximumBytes:32_768)
            guard document.kind == .object,let root = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  Set(root.keys) == ["schemaVersion","claims"],let claims = root["claims"] as? [[String:Any]],claims.count <= 16 else { throw AnswerEvidenceError.invalidResponse }
            for claim in claims {
                let allowed: Set<String>
                switch claim["kind"] as? String {
                case "location":allowed = ["kind","subjectId","locationId","frameId","citations"]
                case "change":allowed = ["kind","subjectId","changeId","citations"]
                case "unknown":allowed = ["kind","subjectId","citations"]
                default:throw AnswerEvidenceError.invalidResponse
                }
                guard Set(claim.keys) == allowed else { throw AnswerEvidenceError.invalidResponse }
            }
            let response = try JSONDecoder().decode(Response.self,from:data)
            guard response.schemaVersion == "1" else { throw AnswerEvidenceError.invalidResponse };return response
        } catch { throw AnswerEvidenceError.invalidResponse }
    }
}
