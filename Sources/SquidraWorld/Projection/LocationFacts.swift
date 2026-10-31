import Foundation
import SquidraDomain

public enum WorldProjectionError: Error, Equatable, Sendable {
    case invalidFact, unsupportedEvent, versionConflict, outOfOrder, notFound, corruptRecord, unavailable, resultLimitExceeded, nonMonotonicKnowledgeTime
}
public enum LocationBasis: String, Codable, Sendable { case observed, inferred }
/// Positive half-open interval at the journal's explicit microsecond precision.
public struct FactInterval: Equatable, Sendable {
    public let fromMicroseconds: Int64
    public let toMicroseconds: Int64?
    public init(from: UTCInstant, to: UTCInstant?) throws {
        let times = try JournalTimes(occurredAt:to,observedAt:from,timeZone:IANATimeZone(identifier:"Etc/UTC"))
        try self.init(fromMicroseconds:times.observedMicroseconds,toMicroseconds:times.occurredMicroseconds)
    }
    public init(fromMicroseconds: Int64, toMicroseconds: Int64?) throws {
        do { _ = try JournalTimes(occurredMicroseconds:toMicroseconds,observedMicroseconds:fromMicroseconds,timeZone:IANATimeZone(identifier:"Etc/UTC")) }
        catch { throw WorldProjectionError.invalidFact }
        guard toMicroseconds.map({ $0 > fromMicroseconds }) ?? true else { throw WorldProjectionError.invalidFact }
        self.fromMicroseconds = fromMicroseconds;self.toMicroseconds = toMicroseconds
    }
    public var from: UTCInstant { try! UTCInstant(secondsSince1970:Double(fromMicroseconds)/1_000_000) }
    public var to: UTCInstant? { toMicroseconds.map { try! UTCInstant(secondsSince1970:Double($0)/1_000_000) } }
}
/// Version-1 internal journal payload. Numeric microseconds are a storage format,
/// not a public HTTP time DTO. External time DTOs must still use RFC 3339.
public struct LocationFactChange: Equatable, Sendable {
    public let subjectID: UUID, locationID: UUID, frameID: UUID
    public let valid: FactInterval
    public let basis: LocationBasis
    public let correctsEventID: UUID?
    public var eventType: String { correctsEventID == nil ? "world.location_asserted" : "world.location_corrected" }
    public init(subjectID: UUID, locationID: UUID, frameID: UUID, valid: FactInterval, basis: LocationBasis, correctsEventID: UUID? = nil) {
        self.subjectID = subjectID;self.locationID = locationID;self.frameID = frameID;self.valid = valid;self.basis = basis;self.correctsEventID = correctsEventID
    }
    private struct Payload: Codable {
        let schemaVersion: String,subjectId: UUID,locationId: UUID,frameId: UUID
        let validFromMicroseconds: Int64,validToMicroseconds: Int64?
        let basis: LocationBasis,correctsEventId: UUID?
    }
    public func encodedPayload() throws -> Data {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(Payload(schemaVersion:"1",subjectId:subjectID,locationId:locationID,frameId:frameID,
            validFromMicroseconds:valid.fromMicroseconds,validToMicroseconds:valid.toMicroseconds,basis:basis,correctsEventId:correctsEventID))
    }
    public static func decode(_ event: WorldEventDraft) throws -> Self {
        guard event.payloadVersion == 1,["world.location_asserted","world.location_corrected"].contains(event.type) else { throw WorldProjectionError.unsupportedEvent }
        do {
            let object = try JSONSerialization.jsonObject(with:event.payload.bytes) as? [String:Any]
            let allowed: Set<String> = ["schemaVersion","subjectId","locationId","frameId","validFromMicroseconds","validToMicroseconds","basis","correctsEventId"]
            guard let object,Set(object.keys).isSubset(of:allowed) else { throw WorldProjectionError.invalidFact }
            let payload = try JSONDecoder().decode(Payload.self,from:event.payload.bytes)
            guard payload.schemaVersion == "1" else { throw WorldProjectionError.unsupportedEvent }
            let change = try Self(subjectID:payload.subjectId,locationID:payload.locationId,frameID:payload.frameId,
                valid:FactInterval(fromMicroseconds:payload.validFromMicroseconds,toMicroseconds:payload.validToMicroseconds),basis:payload.basis,correctsEventID:payload.correctsEventId)
            guard change.eventType == event.type,Set(event.entityIDs).isSuperset(of:[change.subjectID,change.locationID]),
                  change.correctsEventID.map({ event.causationID == $0 }) ?? true else { throw WorldProjectionError.invalidFact }
            return change
        } catch let error as WorldProjectionError { throw error }
        catch { throw WorldProjectionError.invalidFact }
    }
}
public struct WorldLocationFact: Equatable, Sendable {
    public let id: UUID,actorID: UUID,subjectID: UUID,locationID: UUID,frameID: UUID
    public let valid: FactInterval,transaction: FactInterval
    public let confidence: Confidence,basis: LocationBasis,sourceID: String,sourceEventID: UUID
    public let timestamps: ObservationTimestamps
    public init(id: UUID, actorID: UUID, subjectID: UUID, locationID: UUID, frameID: UUID, valid: FactInterval, transaction: FactInterval,
                confidence: Confidence, basis: LocationBasis, sourceID: String, sourceEventID: UUID, timestamps: ObservationTimestamps) {
        self.id = id;self.actorID = actorID;self.subjectID = subjectID;self.locationID = locationID;self.frameID = frameID
        self.valid = valid;self.transaction = transaction;self.confidence = confidence;self.basis = basis
        self.sourceID = sourceID;self.sourceEventID = sourceEventID;self.timestamps = timestamps
    }
}
public enum WorldStateUncertainty: String, Hashable, Sendable { case noEvidence, inferredEvidence, conflictingLocations, projectionBehind }
public struct WorldStateSnapshot: Sendable {
    public let actorID: UUID,subjectID: UUID
    public let validAt: UTCInstant,knownAt: UTCInstant
    public let facts: [WorldLocationFact]
    public let uncertainty: Set<WorldStateUncertainty>
    public let projectedThroughSequence: Int64,availableThroughSequence: Int64
    public init(actorID: UUID, subjectID: UUID, validAt: UTCInstant, knownAt: UTCInstant, facts: [WorldLocationFact],
                projectedThroughSequence: Int64, availableThroughSequence: Int64) {
        self.actorID = actorID;self.subjectID = subjectID;self.validAt = validAt;self.knownAt = knownAt;self.facts = facts
        self.projectedThroughSequence = projectedThroughSequence;self.availableThroughSequence = availableThroughSequence
        var uncertainty: Set<WorldStateUncertainty> = []
        if facts.isEmpty { uncertainty.insert(.noEvidence) }
        if facts.contains(where:{ $0.basis == .inferred }) { uncertainty.insert(.inferredEvidence) }
        if Dictionary(grouping:facts,by:\.frameID).values.contains(where:{ Set($0.map(\.locationID)).count > 1 }) { uncertainty.insert(.conflictingLocations) }
        if projectedThroughSequence < availableThroughSequence { uncertainty.insert(.projectionBehind) }
        self.uncertainty = uncertainty
    }
}
/// Read-only SRS stateAt alias; narrow injection does not grant journal append.
public protocol WorldStateQuery: Sendable {
    func state(actorID: UUID, subjectID: UUID, validAt: UTCInstant, knownAt: UTCInstant, deadline: ContinuousClock.Instant) async throws -> WorldStateSnapshot
}
