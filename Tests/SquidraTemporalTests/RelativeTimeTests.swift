import Foundation
import SquidraDomain
import SquidraTemporal
import XCTest

final class RelativeTimeTests: XCTestCase {
    private func instant(_ value: String) throws -> UTCInstant {
        try UTCInstant(date: XCTUnwrap(ISO8601DateFormatter().date(from: value)))
    }
    private func clock(_ now: String, zone: String = "Europe/Paris") throws -> FixedClock {
        try FixedClock(instant: instant(now), timeZone: IANATimeZone(identifier: zone))
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, zone: String = "Europe/Paris") throws -> ZonedLocalDate {
        try ZonedLocalDate(year: year, month: month, day: day, timeZone: IANATimeZone(identifier: zone))
    }

    func testSpringYesterdayIs23Hours() throws {
        let result = try RelativeTime.resolve(.yesterday, clock: clock("2026-03-30T10:00:00Z"))
        XCTAssertEqual(result.date, try date(2026, 3, 29))
        XCTAssertEqual(result.interval.start, try instant("2026-03-28T23:00:00Z"))
        XCTAssertEqual(result.interval.end, try instant("2026-03-29T22:00:00Z"))
        XCTAssertEqual(result.interval.end!.secondsSince1970 - result.interval.start.secondsSince1970, 23*3600)
    }

    func testAutumnYesterdayIs25Hours() throws {
        let result = try RelativeTime.resolve(.yesterday, clock: clock("2026-10-26T11:00:00Z"))
        XCTAssertEqual(result.date, try date(2026, 10, 25))
        XCTAssertEqual(result.interval.start, try instant("2026-10-24T22:00:00Z"))
        XCTAssertEqual(result.interval.end, try instant("2026-10-25T23:00:00Z"))
        XCTAssertEqual(result.interval.end!.secondsSince1970 - result.interval.start.secondsSince1970, 25*3600)
    }

    func testLocalMidnightUsesClockZoneAndCalendarDate() throws {
        let before = try RelativeTime.resolve(.yesterday, clock: clock("2026-10-24T21:59:59Z"))
        let after = try RelativeTime.resolve(.yesterday, clock: clock("2026-10-24T22:00:00Z"))
        XCTAssertEqual(before.date, try date(2026, 10, 23))
        XCTAssertEqual(after.date, try date(2026, 10, 24))
        let utc = try RelativeTime.resolve(.yesterday, clock: clock("2026-10-24T22:00:00Z", zone: "UTC"))
        XCTAssertEqual(utc.date, try date(2026, 10, 23, zone: "UTC"))
    }

    func testDayBeforeYesterdayAcrossLeapDayAndYear() throws {
        XCTAssertEqual(try RelativeTime.resolve(.dayBeforeYesterday, clock: clock("2024-03-02T12:00:00Z")).date, try date(2024, 2, 29))
        XCTAssertEqual(try RelativeTime.resolve(.dayBeforeYesterday, clock: clock("2026-01-01T12:00:00Z")).date, try date(2025, 12, 30))
    }

    func testRepeatedWallTimeReturnsBothInstants() throws {
        let result = try RelativeTime.resolve(LocalTime(hour: 2, minute: 30), on: date(2026, 10, 25))
        XCTAssertEqual(result, .ambiguous(earlier: try instant("2026-10-25T00:30:00Z"), later: try instant("2026-10-25T01:30:00Z")))
    }

    func testSkippedWallTimeAndOrdinaryTimeAreDistinct() throws {
        XCTAssertEqual(try RelativeTime.resolve(LocalTime(hour: 2, minute: 30), on: date(2026, 3, 29)), .nonexistent)
        XCTAssertEqual(try RelativeTime.resolve(LocalTime(hour: 3, minute: 30), on: date(2026, 3, 29)), .exact(try instant("2026-03-29T01:30:00Z")))
    }

    func testSkippedCivilDayDoesNotNormalizeToAnotherDay() throws {
        XCTAssertThrowsError(try RelativeTime.day(date(2011, 12, 30, zone: "Pacific/Apia"))) {
            XCTAssertEqual($0 as? LocalTimeError, .nonexistentDay)
        }
    }

    func testPersistenceRoundTripKeepsDateAndIANAZone() throws {
        let original = try date(2026, 10, 25)
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ZonedLocalDate.self, from: encoded), original)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(value["timeZone"] as? String, "Europe/Paris")
        for invalid in ["{\"year\":2026,\"month\":2,\"day\":30,\"timeZone\":\"Europe/Paris\"}", "{\"year\":2026,\"month\":2,\"day\":28,\"timeZone\":\"invented\"}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(ZonedLocalDate.self, from: Data(invalid.utf8)))
        }
    }

    func testRelativeDateCannotWrapAcrossTheSupportedEra() throws {
        let utc = try IANATimeZone(identifier: "UTC")
        let firstDay = try FixedClock(instant: UTCInstant(secondsSince1970: -62_135_596_800), timeZone: utc)
        XCTAssertThrowsError(try RelativeTime.resolve(.yesterday, clock: firstDay)) {
            // Foundation's historical calendar may reject the civil date first,
            // or the UTC interval may fall outside the four-digit instant domain.
            XCTAssertTrue(($0 as? LocalTimeError) == .invalidDate || ($0 as? TemporalValidationError) == .invalidInstant)
        }
    }

    func testInvalidDatesAndWallTimesFailWithTypedErrors() {
        for parts in [(2026,2,29),(0,1,1),(10000,1,1),(2026,13,1),(2026,1,0)] {
            XCTAssertThrowsError(try date(parts.0, parts.1, parts.2)) { XCTAssertEqual($0 as? LocalTimeError, .invalidDate) }
        }
        for parts in [(-1,0,0),(24,0,0),(1,60,0),(1,1,60)] {
            XCTAssertThrowsError(try LocalTime(hour: parts.0, minute: parts.1, second: parts.2)) { XCTAssertEqual($0 as? LocalTimeError, .invalidTime) }
        }
    }
}
