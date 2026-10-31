import Foundation
import SquidraDomain

public enum WorldChangesError: Error, Equatable, Sendable { case invalidInterval, invalidCursor, notFound, unsupportedSchema, corruptRecord, unavailable, resultLimitExceeded }
public struct WorldChangesQuery: Equatable, Sendable {
    public let actorID: UUID
    public let window: FactInterval
    public let knownMicroseconds: Int64
    public let subjectID: UUID?,locationID: UUID?
    public init(actorID: UUID, from: UTCInstant, to: UTCInstant?, knownAt: UTCInstant, subjectID: UUID? = nil, locationID: UUID? = nil) throws {
        guard let to else { throw WorldChangesError.invalidInterval }
        do {
            window = try FactInterval(from:from,to:to)
            let times = try JournalTimes(occurredAt:knownAt,observedAt:from,timeZone:IANATimeZone(identifier:"Etc/UTC"))
            knownMicroseconds = times.occurredMicroseconds!
        } catch { throw WorldChangesError.invalidInterval }
        self.actorID = actorID;self.subjectID = subjectID;self.locationID = locationID
    }
    public var knownAt: UTCInstant { try! UTCInstant(secondsSince1970:Double(knownMicroseconds)/1_000_000) }
}
public struct WorldChangesCursor: Equatable, Sendable {
    public let schemaVersion = "1"
    public let query: WorldChangesQuery
    public let throughSequence: Int64,availableThroughSequence: Int64
    public let afterValidMicroseconds: Int64,afterFactID: UUID
    public init(query: WorldChangesQuery, throughSequence: Int64, availableThroughSequence: Int64, afterValidMicroseconds: Int64, afterFactID: UUID) throws {
        guard throughSequence >= 0,availableThroughSequence >= throughSequence,
              afterValidMicroseconds >= query.window.fromMicroseconds,afterValidMicroseconds < query.window.toMicroseconds! else { throw WorldChangesError.invalidCursor }
        self.query = query;self.throughSequence = throughSequence;self.availableThroughSequence = availableThroughSequence
        self.afterValidMicroseconds = afterValidMicroseconds;self.afterFactID = afterFactID
    }
}
public enum WorldChangeKind: String, Sendable { case observation, locationChanged = "location_changed", correction }
public enum WorldChangeUncertainty: String, Hashable, Sendable { case priorStateUnknown, conflictingLocations, inferredEvidence, projectionBehind }
/// Location-state evidence, not proof of a physical trajectory.
public struct WorldChange: Sendable {
    public let id: UUID
    public let kind: WorldChangeKind
    public let current: WorldLocationFact
    public let previous: [WorldLocationFact]
    public let supportingEventIDs: [UUID]
    public let uncertainty: Set<WorldChangeUncertainty>
    public var effectiveAt: UTCInstant { current.valid.from }
    public init(current: WorldLocationFact, previous: [WorldLocationFact], isCorrection: Bool, conflictingCurrent: Bool, projectionBehind: Bool) throws {
        guard previous.allSatisfy({ $0.actorID == current.actorID && $0.subjectID == current.subjectID && $0.frameID == current.frameID }),
              !isCorrection || !previous.isEmpty else { throw WorldChangesError.corruptRecord }
        let places = Set(previous.map(\.locationID))
        if isCorrection { kind = .correction }
        else if places.count == 1,places.first != current.locationID,!conflictingCurrent { kind = .locationChanged }
        else { kind = .observation }
        var uncertainty: Set<WorldChangeUncertainty> = []
        if previous.isEmpty { uncertainty.insert(.priorStateUnknown) }
        if places.count > 1 || conflictingCurrent { uncertainty.insert(.conflictingLocations) }
        if current.basis == .inferred || previous.contains(where:{ $0.basis == .inferred }) { uncertainty.insert(.inferredEvidence) }
        if projectionBehind { uncertainty.insert(.projectionBehind) }
        id = current.id;self.current = current;self.previous = previous
        supportingEventIDs = Set([current.sourceEventID]+previous.map(\.sourceEventID)).sorted { $0.uuidString < $1.uuidString }
        self.uncertainty = uncertainty
    }
}
public struct WorldChangesPage: Sendable {
    public let changes: [WorldChange]
    public let next: WorldChangesCursor?
    public let throughSequence: Int64,availableThroughSequence: Int64
    public var projectionBehind: Bool { throughSequence < availableThroughSequence }
    public init(changes: [WorldChange], next: WorldChangesCursor?, throughSequence: Int64, availableThroughSequence: Int64) {
        self.changes = changes;self.next = next;self.throughSequence = throughSequence;self.availableThroughSequence = availableThroughSequence
    }
}
public protocol WorldChangesQuerying: Sendable {
    func changes(_ query: WorldChangesQuery, cursor: WorldChangesCursor?, limit: Int, deadline: ContinuousClock.Instant) async throws -> WorldChangesPage
}
