import Foundation
import SquidraDomain

public enum LocalTimeError: Error, Equatable, Sendable {
    case invalidDate
    case invalidTime
    case nonexistentDay
}

/// A Gregorian civil date stored together with its IANA zone. Encoding is an
/// internal persistence value, not an unversioned public API DTO.
public struct ZonedLocalDate: Hashable, Sendable, Codable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let timeZone: IANATimeZone

    public init(year: Int, month: Int, day: Int, timeZone: IANATimeZone) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day)
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: parts),
              calendar.dateComponents([.year, .month, .day], from: date) == parts else { throw LocalTimeError.invalidDate }
        self.year = year; self.month = month; self.day = day; self.timeZone = timeZone
    }

    private enum CodingKeys: String, CodingKey { case year, month, day, timeZone }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(year: values.decode(Int.self, forKey: .year), month: values.decode(Int.self, forKey: .month),
                day: values.decode(Int.self, forKey: .day),
                timeZone: IANATimeZone(identifier: values.decode(String.self, forKey: .timeZone)))
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid local date or IANA zone"))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(year, forKey: .year); try values.encode(month, forKey: .month)
        try values.encode(day, forKey: .day); try values.encode(timeZone.identifier, forKey: .timeZone)
    }
}

public struct LocalTime: Equatable, Sendable {
    public let hour: Int
    public let minute: Int
    public let second: Int
    public init(hour: Int, minute: Int, second: Int = 0) throws {
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            throw LocalTimeError.invalidTime
        }
        self.hour = hour; self.minute = minute; self.second = second
    }
}

public enum LocalTimeResolution: Equatable, Sendable {
    case exact(UTCInstant)
    case ambiguous(earlier: UTCInstant, later: UTCInstant)
    case nonexistent
}

public struct ResolvedLocalDay: Equatable, Sendable {
    public let date: ZonedLocalDate
    public let interval: InstantInterval
}

public enum RelativeTime {
    public enum Expression: Sendable { case yesterday, dayBeforeYesterday }

    /// Calendar days, never a 24-hour subtraction from the wall instant.
    public static func resolve(_ expression: Expression, clock: some SquidraDomain.Clock) throws -> ResolvedLocalDay {
        let zone = clock.timezone()
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(identifier: zone.identifier)!
        let today = local.dateComponents([.era, .year, .month, .day], from: try clock.now().date)
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = TimeZone(secondsFromGMT: 0)!
        guard today.era == 1, let reference = civil.date(from: today),
              let shifted = civil.date(byAdding: .day, value: expression == .yesterday ? -1 : -2, to: reference) else {
            throw LocalTimeError.invalidDate
        }
        let parts = civil.dateComponents([.era, .year, .month, .day], from: shifted)
        guard parts.era == 1 else { throw LocalTimeError.invalidDate }
        let date = try ZonedLocalDate(year: parts.year!, month: parts.month!, day: parts.day!, timeZone: zone)
        return try day(date)
    }

    public static func day(_ date: ZonedLocalDate) throws -> ResolvedLocalDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: date.timeZone.identifier)!
        let parts = DateComponents(year: date.year, month: date.month, day: date.day)
        // Foundation may normalize a nonexistent civil date. Reject that result.
        guard let candidate = calendar.date(from: parts),
              calendar.dateComponents([.year, .month, .day], from: candidate) == parts,
              let bounds = calendar.dateInterval(of: .day, for: candidate) else { throw LocalTimeError.nonexistentDay }
        return try ResolvedLocalDay(date: date, interval: InstantInterval(
            start: UTCInstant(date: bounds.start), end: UTCInstant(date: bounds.end)))
    }

    /// Both repeated occurrences are returned; a skipped wall time is not shifted.
    public static func resolve(_ time: LocalTime, on date: ZonedLocalDate) throws -> LocalTimeResolution {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: date.timeZone.identifier)!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: date.year, month: date.month, day: date.day,
            hour: time.hour, minute: time.minute, second: time.second)
        let anchor = utc.date(from: parts)!.addingTimeInterval(-172_800)
        func occurrence(_ policy: Calendar.RepeatedTimePolicy) -> Date? {
            guard let candidate = calendar.nextDate(after: anchor, matching: parts,
                matchingPolicy: .strict, repeatedTimePolicy: policy, direction: .forward),
                calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: candidate) == parts else { return nil }
            return candidate
        }
        guard let first = occurrence(.first), let last = occurrence(.last) else { return .nonexistent }
        let earlier = try UTCInstant(date: min(first, last)), later = try UTCInstant(date: max(first, last))
        return earlier == later ? .exact(earlier) : .ambiguous(earlier: earlier, later: later)
    }
}
