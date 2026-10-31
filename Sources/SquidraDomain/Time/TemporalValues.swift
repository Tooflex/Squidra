import Foundation

public enum TemporalValidationError: Error, Equatable, Sendable {
    case invalidInstant
    case invalidTimeZone
    case reversedInterval
    case negativeElapsedDuration
}

/// An absolute UTC instant. Four-digit RFC 3339 years are representable.
/// Wire DTOs must encode RFC 3339 with an explicit offset, not a bare number.
public struct UTCInstant: Hashable, Comparable, Sendable {
    public let secondsSince1970: Double

    public init(secondsSince1970: Double) throws {
        guard secondsSince1970.isFinite,
              secondsSince1970 >= -62_135_596_800,
              secondsSince1970 < 253_402_300_800 else {
            throw TemporalValidationError.invalidInstant
        }
        self.secondsSince1970 = secondsSince1970
    }

    public init(date: Date) throws {
        try self.init(secondsSince1970: date.timeIntervalSince1970)
    }

    public var date: Date { Date(timeIntervalSince1970: secondsSince1970) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.secondsSince1970 < rhs.secondsSince1970
    }
}

/// An IANA identifier, not an invented fixed offset. Preserve it alongside
/// instants when local calendar meaning matters (ADR-008).
public struct IANATimeZone: Hashable, Sendable {
    public let identifier: String

    public init(identifier: String) throws {
        guard (TimeZone.knownTimeZoneIdentifiers.contains(identifier)
               || ["UTC", "GMT", "Etc/UTC", "Etc/GMT"].contains(identifier)),
              TimeZone(identifier: identifier) != nil else {
            throw TemporalValidationError.invalidTimeZone
        }
        self.identifier = identifier
    }
}

/// No timestamp substitutes for another. A source may have clock skew;
/// this value does not manufacture causal ordering from wall-clock values.
public struct ObservationTimestamps: Equatable, Sendable {
    public let occurredAt: UTCInstant?
    public let observedAt: UTCInstant
    public let recordedAt: UTCInstant
    public let timeZone: IANATimeZone

    public init(occurredAt: UTCInstant?, observedAt: UTCInstant,
                recordedAt: UTCInstant, timeZone: IANATimeZone) {
        self.occurredAt = occurredAt
        self.observedAt = observedAt
        self.recordedAt = recordedAt
        self.timeZone = timeZone
    }
}

/// Half-open [start, end); nil end means unbounded, equal bounds are empty.
/// This is a valid-time interval; transactional versions require strict
/// positive length in the persistence contract (ADR-008).
public struct InstantInterval: Equatable, Sendable {
    public let start: UTCInstant
    public let end: UTCInstant?

    public init(start: UTCInstant, end: UTCInstant?) throws {
        guard end.map({ $0 >= start }) ?? true else {
            throw TemporalValidationError.reversedInterval
        }
        self.start = start
        self.end = end
    }

    public func contains(_ instant: UTCInstant) -> Bool {
        instant >= start && (end.map { instant < $0 } ?? true)
    }
}
