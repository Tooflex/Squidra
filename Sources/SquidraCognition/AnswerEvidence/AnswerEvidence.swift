import Foundation
import SquidraDomain
import SquidraWorld

public enum AnswerEvidenceError: Error, Equatable, Sendable {
    case invalidEvidence, evidenceLimitExceeded, clockUnavailable, invalidResponse, requestMismatch, invalidCitation, unsupportedClaim, conflictingEvidence, staleEvidence, insufficientEvidence, incompleteEvidence
}
public enum AnswerIntent: String, Encodable, Sendable { case historical, latestObservation = "latest_observation", current }
public enum EvidenceFreshness: String, Encodable, Sendable { case fresh, stale, clockSkew = "clock_skew" }
public struct AnswerFreshnessPolicy: Sendable {
    public let maximumObservationAgeSeconds: Double
    public let minimumCurrentConfidence: Confidence
    public let allowInferredCurrent: Bool
    public init(maximumObservationAgeSeconds: Double, minimumCurrentConfidence: Confidence, allowInferredCurrent: Bool = false) throws {
        guard maximumObservationAgeSeconds.isFinite,maximumObservationAgeSeconds > 0 else { throw AnswerEvidenceError.invalidEvidence }
        self.maximumObservationAgeSeconds = maximumObservationAgeSeconds;self.minimumCurrentConfidence = minimumCurrentConfidence;self.allowInferredCurrent = allowInferredCurrent
    }
}
public struct AnswerEvidenceDTO: Encodable, Sendable {
    public let schemaVersion = "1"
    public let id: UUID,subjectId: UUID,locationId: UUID,frameId: UUID
    public let source: String,confidence: Double,basis: LocationBasis
    public let occurredAt: String?,observedAt: String,recordedAt: String,timeZone: String
    public let observationAgeSeconds: Double?,freshness: EvidenceFreshness
}
/// Constructed by the trusted host from scoped read ports. Model text cannot
/// add evidence or replace its timestamps/confidence. Ages refresh on validation.
public struct AnswerEvidenceContext: Sendable {
    enum Scope: Sendable { case state(WorldStateSnapshot), changes(WorldChangesQuery) }
    let scope: Scope
    let clock: any SquidraDomain.Clock
    let policy: AnswerFreshnessPolicy
    let facts: [UUID:WorldLocationFact]
    let changes: [UUID:WorldChange]
    let subjects: Set<UUID>
    public let actorID: UUID,intent: AnswerIntent
    public let isPartial: Bool
    public let uncertainty: Set<String>
    public init(snapshot: WorldStateSnapshot, expectedActor: UUID, intent: AnswerIntent, clock: any SquidraDomain.Clock, policy: AnswerFreshnessPolicy) throws {
        guard snapshot.actorID == expectedActor,snapshot.projectedThroughSequence >= 0,snapshot.availableThroughSequence >= snapshot.projectedThroughSequence else { throw AnswerEvidenceError.invalidEvidence }
        let times = try Self.times(snapshot.validAt,snapshot.knownAt)
        guard snapshot.facts.allSatisfy({ $0.subjectID == snapshot.subjectID && Self.contains($0.valid,times.observedMicroseconds) && Self.contains($0.transaction,times.occurredMicroseconds!) }) else { throw AnswerEvidenceError.invalidEvidence }
        facts = try Self.collect(snapshot.facts,actor:expectedActor);changes = [:];subjects = [snapshot.subjectID]
        scope = .state(snapshot);actorID = expectedActor;self.intent = intent;self.clock = clock;self.policy = policy
        isPartial = snapshot.uncertainty.contains(.projectionBehind)
        uncertainty = Set(snapshot.uncertainty.map(\.rawValue))
    }
    public init(page: WorldChangesPage, query: WorldChangesQuery, expectedActor: UUID, clock: any SquidraDomain.Clock, policy: AnswerFreshnessPolicy) throws {
        guard query.actorID == expectedActor,page.changes.count <= 128,page.throughSequence >= 0,page.availableThroughSequence >= page.throughSequence,
              page.next.map({ $0.query == query && $0.throughSequence == page.throughSequence && $0.availableThroughSequence == page.availableThroughSequence }) ?? true else { throw AnswerEvidenceError.invalidEvidence }
        var all: [WorldLocationFact] = [],changes: [UUID:WorldChange] = [:],subjects: Set<UUID> = []
        var uncertainty: Set<String> = []
        for change in page.changes {
            guard changes[change.id] == nil,change.current.valid.fromMicroseconds >= query.window.fromMicroseconds,
                  change.current.valid.fromMicroseconds < query.window.toMicroseconds!,Self.contains(change.current.transaction,query.knownMicroseconds),
                  query.subjectID.map({ $0 == change.current.subjectID }) ?? true,
                  query.locationID.map({ location in location == change.current.locationID || change.previous.contains(where:{ $0.locationID == location }) }) ?? true else { throw AnswerEvidenceError.invalidEvidence }
            changes[change.id] = change;subjects.insert(change.current.subjectID)
            all += [change.current]+change.previous;uncertainty.formUnion(change.uncertainty.map(\.rawValue))
        }
        if let subject = query.subjectID { subjects.insert(subject) }
        facts = try Self.collect(all,actor:expectedActor);self.changes = changes;self.subjects = subjects
        scope = .changes(query);actorID = expectedActor;intent = .historical;self.clock = clock;self.policy = policy
        isPartial = page.next != nil || page.projectionBehind
        if page.next != nil { uncertainty.insert("partial_page") };if page.projectionBehind { uncertainty.insert("projectionBehind") }
        self.uncertainty = uncertainty
    }
    public func evidence() throws -> [AnswerEvidenceDTO] { try refreshed().0.values.sorted { $0.id.uuidString < $1.id.uuidString } }
    func refreshed() throws -> ([UUID:AnswerEvidenceDTO],UTCInstant) {
        let now: UTCInstant
        do { now = try clock.now() } catch { throw AnswerEvidenceError.clockUnavailable }
        var records: [UUID:AnswerEvidenceDTO] = [:]
        for (id,fact) in facts {
            let age = now.secondsSince1970-fact.timestamps.observedAt.secondsSince1970
            let freshness: EvidenceFreshness = age < 0 ? .clockSkew : (age <= policy.maximumObservationAgeSeconds ? .fresh : .stale)
            records[id] = AnswerEvidenceDTO(id:id,subjectId:fact.subjectID,locationId:fact.locationID,frameId:fact.frameID,source:fact.sourceID,
                confidence:fact.confidence.value,basis:fact.basis,occurredAt:try fact.timestamps.occurredAt.map(Self.utc),observedAt:try Self.utc(fact.timestamps.observedAt),
                recordedAt:try Self.utc(fact.timestamps.recordedAt),timeZone:fact.timestamps.timeZone.identifier,observationAgeSeconds:age < 0 ? nil : age,freshness:freshness)
        }
        return (records,now)
    }
    static func contains(_ interval: FactInterval,_ time: Int64) -> Bool { interval.fromMicroseconds <= time && (interval.toMicroseconds.map({ time < $0 }) ?? true) }
    private static func collect(_ values: [WorldLocationFact], actor: UUID) throws -> [UUID:WorldLocationFact] {
        var result: [UUID:WorldLocationFact] = [:]
        for fact in values {
            guard fact.actorID == actor,fact.id == fact.sourceEventID,!fact.sourceID.isEmpty,fact.sourceID.utf8.count <= 256,
                  !fact.sourceID.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw AnswerEvidenceError.invalidEvidence }
            if let old = result[fact.sourceEventID],old != fact { throw AnswerEvidenceError.invalidEvidence }
            result[fact.sourceEventID] = fact
            guard result.count <= 256 else { throw AnswerEvidenceError.evidenceLimitExceeded }
        }
        return result
    }
    static func times(_ valid: UTCInstant,_ known: UTCInstant) throws -> JournalTimes {
        do { return try JournalTimes(occurredAt:known,observedAt:valid,timeZone:IANATimeZone(identifier:"Etc/UTC")) }
        catch { throw AnswerEvidenceError.invalidEvidence }
    }
    static func utc(_ instant: UTCInstant) throws -> String {
        let micros = try times(instant,instant).observedMicroseconds
        var seconds = micros/1_000_000,fraction = micros%1_000_000
        if fraction < 0 { seconds -= 1;fraction += 1_000_000 }
        let formatter = ISO8601DateFormatter();formatter.timeZone = TimeZone(secondsFromGMT:0);formatter.formatOptions = [.withInternetDateTime]
        let base = formatter.string(from:Date(timeIntervalSince1970:Double(seconds)))
        guard base.count == 20,base.hasSuffix("Z") else { throw AnswerEvidenceError.invalidEvidence }
        return String(base.dropLast())+String(format:".%06lldZ",fraction)
    }
}
