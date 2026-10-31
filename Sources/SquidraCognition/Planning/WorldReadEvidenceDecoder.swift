import Foundation
import SquidraDomain
import SquidraTools
import SquidraWorld

public struct WorldReadEvidence: Sendable {
    public let context: AnswerEvidenceContext
    public let continuation: String?
    public let entityNotFound: Bool
}
/// Reconstructs bounded factual data from registered read-tool outputs. Source
/// text stays data; schema validation never grants policy or authenticates SQL.
public struct WorldReadEvidenceDecoder: Sendable {
    private let catalog: ToolCatalog
    public init() throws {
        catalog = try ToolCatalog(definitions:[WorldLocationTool.definition(),WorldChangesTool.definition()])
    }
    public func decode(_ result: UntrustedToolResult, proposal: ReadProposal, actorID: UUID, intent: AnswerIntent,
                       clock: any SquidraDomain.Clock, policy: AnswerFreshnessPolicy) throws -> WorldReadEvidence {
        do {
            guard result.tool == proposal.tool else { throw AnswerEvidenceError.invalidEvidence }
            _ = try catalog.validateInput(proposal.arguments,for:proposal.tool)
            _ = try catalog.validateOutput(result.payload,for:proposal.tool)
            if proposal.tool == (try WorldLocationTool.definition()).id {
                return try location(result.payload,proposal:proposal,actor:actorID,intent:intent,clock:clock,policy:policy)
            }
            guard proposal.tool == (try WorldChangesTool.definition()).id, intent == .historical else { throw AnswerEvidenceError.invalidEvidence }
            return try changes(result.payload,proposal:proposal,actor:actorID,clock:clock,policy:policy)
        } catch { throw AnswerEvidenceError.invalidEvidence }
    }
    private struct Interval: Decodable {
        let from: String, to: String?
        func value() throws -> FactInterval { try FactInterval(from:RFC3339.parse(from),to:to.map(RFC3339.parse)) }
    }
    private struct Fact: Decodable {
        let id: UUID,subjectId: UUID,locationId: UUID,frameId: UUID,sourceEventId: UUID
        let source: String,basis: LocationBasis,confidence: Double
        let occurredAt: String?,observedAt: String,recordedAt: String,timeZone: String
        let valid: Interval,transaction: Interval
        func value(actor: UUID) throws -> WorldLocationFact {
            let transaction = try transaction.value(), recorded = try RFC3339.parse(recordedAt)
            guard id == sourceEventId, !source.isEmpty, source.utf8.count <= 256,
                  !source.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
                  transaction.from == recorded else { throw AnswerEvidenceError.invalidEvidence }
            return try WorldLocationFact(id:id,actorID:actor,subjectID:subjectId,locationID:locationId,frameID:frameId,
                valid:valid.value(),transaction:transaction,confidence:Confidence(confidence),basis:basis,sourceID:source,sourceEventID:sourceEventId,
                timestamps:ObservationTimestamps(occurredAt:occurredAt.map(RFC3339.parse),observedAt:RFC3339.parse(observedAt),
                    recordedAt:recorded,timeZone:IANATimeZone(identifier:timeZone)))
        }
    }
    private static func sequence(_ value: String?) throws -> Int64 {
        guard let value, let number = Int64(value), number >= 0, String(number) == value else { throw AnswerEvidenceError.invalidEvidence }
        return number
    }
    private static func times(valid: String, known: String) throws -> JournalTimes {
        try JournalTimes(occurredAt:RFC3339.parse(known),observedAt:RFC3339.parse(valid),timeZone:IANATimeZone(identifier:"Etc/UTC"))
    }
    private struct LocationRequest: Decodable { let entityId: UUID,validAt: String,knownAt: String }
    private struct LocationResponse: Decodable {
        let actorId: UUID,entityId: UUID,validAt: String,knownAt: String,status: String
        let facts: [Fact],uncertainty: [String]
        let projectedThroughSequence: String?,availableThroughSequence: String?
    }
    private func location(_ bytes: Data, proposal: ReadProposal, actor: UUID, intent: AnswerIntent,
                          clock: any SquidraDomain.Clock, policy: AnswerFreshnessPolicy) throws -> WorldReadEvidence {
        let request = try JSONDecoder().decode(LocationRequest.self,from:proposal.arguments)
        let response = try JSONDecoder().decode(LocationResponse.self,from:bytes)
        let expected = try Self.times(valid:request.validAt,known:request.knownAt)
        let actual = try Self.times(valid:response.validAt,known:response.knownAt)
        guard response.actorId == actor, response.entityId == request.entityId,
              proposal.target == "entity:"+request.entityId.uuidString.lowercased(),
              actual.observedMicroseconds == expected.observedMicroseconds, actual.occurredMicroseconds == expected.occurredMicroseconds,
              Set(response.uncertainty).count == response.uncertainty.count else { throw AnswerEvidenceError.invalidEvidence }
        let facts = try response.facts.map { try $0.value(actor:actor) }
        guard Set(facts.map(\.id)).count == facts.count else { throw AnswerEvidenceError.invalidEvidence }
        let notFound = response.status == "not_found"
        let projected: Int64, available: Int64
        if notFound {
            guard facts.isEmpty, response.projectedThroughSequence == nil, response.availableThroughSequence == nil else { throw AnswerEvidenceError.invalidEvidence }
            // Internal empty context has no source watermark to advertise.
            // entityNotFound remains explicit in this immutable result.
            projected = 0; available = 0
        } else {
            projected = try Self.sequence(response.projectedThroughSequence); available = try Self.sequence(response.availableThroughSequence)
            guard response.status == (facts.isEmpty ? "no_evidence" : "evidence") else { throw AnswerEvidenceError.invalidEvidence }
        }
        let snapshot = WorldStateSnapshot(actorID:actor,subjectID:request.entityId,validAt:expected.observedAt,knownAt:expected.occurredAt!,
            facts:facts,projectedThroughSequence:projected,availableThroughSequence:available)
        guard Set(snapshot.uncertainty.map(\.rawValue)) == Set(response.uncertainty) else { throw AnswerEvidenceError.invalidEvidence }
        let context = try AnswerEvidenceContext(snapshot:snapshot,expectedActor:actor,intent:intent,clock:clock,policy:policy)
        return WorldReadEvidence(context:context,continuation:nil,entityNotFound:notFound)
    }
    private struct ChangesRequest: Decodable {
        let from: String,to: String,knownAt: String,subjectId: UUID?,locationId: UUID?,limit: Int
    }
    private struct Change: Decodable {
        let id: UUID,subjectId: UUID,kind: String,effectiveAt: String,currentFactId: UUID
        let previousFactIds: [UUID],supportingEventIds: [UUID],uncertainty: [String]
    }
    private struct ChangesResponse: Decodable {
        let actorId: UUID,from: String,to: String,knownAt: String,subjectId: UUID?,locationId: UUID?
        let changes: [Change],facts: [Fact],projectedThroughSequence: String,availableThroughSequence: String
        let projectionBehind: Bool,next: String?
    }
    private func changes(_ bytes: Data, proposal: ReadProposal, actor: UUID,
                         clock: any SquidraDomain.Clock, policy: AnswerFreshnessPolicy) throws -> WorldReadEvidence {
        let request = try JSONDecoder().decode(ChangesRequest.self,from:proposal.arguments)
        let query = try WorldChangesQuery(actorID:actor,from:RFC3339.parse(request.from),to:RFC3339.parse(request.to),
            knownAt:RFC3339.parse(request.knownAt),subjectID:request.subjectId,locationID:request.locationId)
        let response = try JSONDecoder().decode(ChangesResponse.self,from:bytes)
        let returned = try WorldChangesQuery(actorID:response.actorId,from:RFC3339.parse(response.from),to:RFC3339.parse(response.to),
            knownAt:RFC3339.parse(response.knownAt),subjectID:response.subjectId,locationID:response.locationId)
        let projected = try Self.sequence(response.projectedThroughSequence), available = try Self.sequence(response.availableThroughSequence)
        guard query == returned, proposal.target == (query.subjectID.map { "entity:"+$0.uuidString.lowercased() } ?? "world:changes"),
              available >= projected, response.projectionBehind == (projected < available), response.changes.count <= request.limit else { throw AnswerEvidenceError.invalidEvidence }
        var facts: [UUID:WorldLocationFact] = [:]
        for raw in response.facts {
            let fact = try raw.value(actor:actor)
            guard facts.updateValue(fact,forKey:fact.id) == nil else { throw AnswerEvidenceError.invalidEvidence }
        }
        var decoded: [WorldChange] = [], used: Set<UUID> = [], last: (Int64,String)?
        for change in response.changes {
            guard let current = facts[change.currentFactId], change.id == current.id, change.subjectId == current.subjectID,
                  Set(change.previousFactIds).count == change.previousFactIds.count, !change.previousFactIds.contains(current.id),
                  Set(change.supportingEventIds).count == change.supportingEventIds.count,
                  Set(change.uncertainty).count == change.uncertainty.count else { throw AnswerEvidenceError.invalidEvidence }
            let previous = try change.previousFactIds.map { id in
                guard let fact = facts[id] else { throw AnswerEvidenceError.invalidEvidence }; return fact
            }
            let position = (current.valid.fromMicroseconds,current.id.uuidString)
            let effective = try Self.times(valid:change.effectiveAt,known:change.effectiveAt).observedMicroseconds
            guard effective == position.0, last.map({ position > $0 }) ?? true,
                  previous.allSatisfy({ prior in
                      if change.kind == "correction" { return prior.transaction.toMicroseconds == current.transaction.fromMicroseconds }
                      return prior.valid.toMicroseconds == current.valid.fromMicroseconds && AnswerEvidenceContext.contains(prior.transaction,query.knownMicroseconds)
                  }) else { throw AnswerEvidenceError.invalidEvidence }
            let value = try WorldChange(current:current,previous:previous,isCorrection:change.kind == "correction",
                conflictingCurrent:change.uncertainty.contains("conflictingLocations"),projectionBehind:response.projectionBehind)
            guard value.kind.rawValue == change.kind, Set(value.supportingEventIDs) == Set(change.supportingEventIds),
                  Set(value.uncertainty.map(\.rawValue)) == Set(change.uncertainty) else { throw AnswerEvidenceError.invalidEvidence }
            used.formUnion([current.id]+change.previousFactIds); decoded.append(value); last = position
        }
        guard used == Set(facts.keys), response.next == nil || (!decoded.isEmpty && Data(base64Encoded:response.next!) != nil) else { throw AnswerEvidenceError.invalidEvidence }
        let page = WorldChangesPage(changes:decoded,next:nil,throughSequence:projected,availableThroughSequence:available)
        let context = try AnswerEvidenceContext(page:page,query:query,expectedActor:actor,clock:clock,policy:policy,hasAdditionalPages:response.next != nil)
        return WorldReadEvidence(context:context,continuation:response.next,entityNotFound:false)
    }
}
