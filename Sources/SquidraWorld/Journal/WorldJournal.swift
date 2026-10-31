import Foundation
import SquidraDomain

public enum WorldJournalError: Error, Equatable, Sendable {
    case invalidEvent, invalidCursor, versionConflict, idempotencyConflict, notFound, corruptRecord, unavailable, unsupportedEvent
}
/// Explicit PostgreSQL-compatible precision. Original wall/timezone meaning is
/// retained; unknown occurrence is never replaced with observation/record time.
public struct JournalTimes: Equatable, Sendable {
    public let occurredMicroseconds: Int64?
    public let observedMicroseconds: Int64
    public let timeZone: IANATimeZone
    public init(occurredAt: UTCInstant?, observedAt: UTCInstant, timeZone: IANATimeZone) throws {
        try self.init(occurredMicroseconds:occurredAt.map { Int64(($0.secondsSince1970*1_000_000).rounded()) },
            observedMicroseconds:Int64((observedAt.secondsSince1970*1_000_000).rounded()),timeZone:timeZone)
    }
    public init(occurredMicroseconds: Int64?, observedMicroseconds: Int64, timeZone: IANATimeZone) throws {
        guard Self.valid(observedMicroseconds),occurredMicroseconds.map(Self.valid) ?? true else { throw WorldJournalError.invalidEvent }
        self.occurredMicroseconds = occurredMicroseconds;self.observedMicroseconds = observedMicroseconds;self.timeZone = timeZone
    }
    public var occurredAt: UTCInstant? { occurredMicroseconds.map { try! UTCInstant(secondsSince1970:Double($0)/1_000_000) } }
    public var observedAt: UTCInstant { try! UTCInstant(secondsSince1970:Double(observedMicroseconds)/1_000_000) }
    static func valid(_ value: Int64) -> Bool {
        let seconds = Double(value)/1_000_000
        return value >= -62_135_596_800_000_000 && value < 253_402_300_800_000_000
            && seconds >= -62_135_596_800 && seconds < 253_402_300_800
    }
}
public struct WorldEventDraft: Equatable, Sendable {
    public let id: UUID, actorID: UUID, streamID: UUID
    public let entityIDs: [UUID]
    public let type: String
    public let times: JournalTimes
    public let sourceID: String
    public let confidence: Confidence
    public let payloadVersion: Int
    public let payload: JSONDocument
    public let causationID: UUID?
    public let correlationID: UUID
    public init(id: UUID = UUID(), actorID: UUID, streamID: UUID, entityIDs: [UUID], type: String, times: JournalTimes,
                sourceID: String, confidence: Confidence, payloadVersion: Int, payload: Data, causationID: UUID? = nil, correlationID: UUID) throws {
        guard (1...256).contains(entityIDs.count),!type.isEmpty,type.utf8.count <= 128,
              type.utf8.first.map({ (97...122).contains($0) }) ?? false,
              type.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [95,46].contains($0) }),
              !sourceID.isEmpty,sourceID.utf8.count <= 256,sourceID.trimmingCharacters(in:.whitespacesAndNewlines) == sourceID,
              !sourceID.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              (1...Int(Int32.max)).contains(payloadVersion),causationID != id else { throw WorldJournalError.invalidEvent }
        do {
            let document = try JSONDocument(payload,maximumBytes:65_536)
            guard document.kind == .object,!document.containsNUL else { throw WorldJournalError.invalidEvent }
            self.payload = document
        } catch { throw WorldJournalError.invalidEvent }
        self.id = id;self.actorID = actorID;self.streamID = streamID
        self.entityIDs = Set(entityIDs).sorted { $0.uuidString < $1.uuidString }
        self.type = type;self.times = times;self.sourceID = sourceID;self.confidence = confidence
        self.payloadVersion = payloadVersion;self.causationID = causationID;self.correlationID = correlationID
    }
}
public struct JournalEvent: Equatable, Sendable {
    public let sequence: Int64, streamVersion: Int64
    public let draft: WorldEventDraft
    public let recordedMicroseconds: Int64
    public var recordedAt: UTCInstant { try! UTCInstant(secondsSince1970:Double(recordedMicroseconds)/1_000_000) }
    public init(sequence: Int64, streamVersion: Int64, draft: WorldEventDraft, recordedMicroseconds: Int64) throws {
        guard sequence > 0,streamVersion > 0,JournalTimes.valid(recordedMicroseconds) else { throw WorldJournalError.corruptRecord }
        self.sequence = sequence;self.streamVersion = streamVersion;self.draft = draft;self.recordedMicroseconds = recordedMicroseconds
    }
}
public struct JournalAppend: Sendable {
    public let event: JournalEvent
    public let created: Bool
    public init(event: JournalEvent, created: Bool) { self.event = event;self.created = created }
}
public struct JournalCursor: Equatable, Sendable {
    public let schemaVersion = "1"
    public let actorID: UUID
    public let afterSequence: Int64, throughSequence: Int64
    public init(actorID: UUID, afterSequence: Int64, throughSequence: Int64) throws {
        guard afterSequence >= 0,throughSequence >= afterSequence else { throw WorldJournalError.invalidCursor }
        self.actorID = actorID;self.afterSequence = afterSequence;self.throughSequence = throughSequence
    }
}
public struct JournalPage: Sendable {
    public let events: [JournalEvent]
    public let next: JournalCursor?
    public let throughSequence: Int64
    public init(events: [JournalEvent], next: JournalCursor?, throughSequence: Int64) {
        self.events = events;self.next = next;self.throughSequence = throughSequence
    }
}
/// SRS EventStore append alias. Journal keys are separate from the action ledger.
public protocol WorldRepository: Sendable {
    func append(_ event: WorldEventDraft, expectedVersion: Int64, idempotencyKey: String, deadline: ContinuousClock.Instant) async throws -> JournalAppend
    func page(actorID: UUID, afterSequence: Int64, cursor: JournalCursor?, limit: Int, deadline: ContinuousClock.Instant) async throws -> JournalPage
}
public struct ProjectionCheckpoint: Sendable {
    public let projectionVersion: Int
    public let lastSequence: Int64?
    public let state: JSONDocument
    public init(projectionVersion: Int, lastSequence: Int64?, state: JSONDocument) throws {
        guard projectionVersion > 0,lastSequence.map({ $0 > 0 }) ?? true,state.kind == .object else { throw WorldJournalError.invalidEvent }
        self.projectionVersion = projectionVersion;self.lastSequence = lastSequence;self.state = state
    }
}
public protocol WorldProjector: Sendable {
    func apply(_ event: JournalEvent) async throws
    func checkpoint() async throws -> ProjectionCheckpoint
}
