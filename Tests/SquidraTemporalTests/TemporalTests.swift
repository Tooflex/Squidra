import Foundation
import SquidraDomain
import SquidraTemporal
import XCTest

final class TemporalTests: XCTestCase {
    private func instant(_ seconds: Double) throws -> UTCInstant {
        try UTCInstant(secondsSince1970: seconds)
    }

    private func observation(_ sequence: Int64, occurred: Double?, observed: Double) throws -> JournalObservation {
        try JournalObservation(id: UUID(), sequence: sequence,
            timestamps: ObservationTimestamps(occurredAt: try occurred.map(instant),
                observedAt: try instant(observed), recordedAt: try instant(observed + 10),
                timeZone: try IANATimeZone(identifier: "Europe/Paris")),
            sourceID: "camera:desk", confidence: try Confidence(0.9))
    }

    func testThreeTimestampsRemainDistinct() throws {
        let event = try observation(1, occurred: 100, observed: 200)
        XCTAssertEqual(event.timestamps.occurredAt, try instant(100))
        XCTAssertEqual(event.timestamps.observedAt, try instant(200))
        XCTAssertEqual(event.timestamps.recordedAt, try instant(210))
        XCTAssertEqual(event.timestamps.timeZone.identifier, "Europe/Paris")
    }

    func testLateObservationChangesViewWithoutChangingJournalOrProvenance() throws {
        let first = try observation(1, occurred: 200, observed: 210)
        let late = try observation(2, occurred: 100, observed: 300)
        let input = [late, first]
        XCTAssertEqual(try TemporalHistory.journalOrder(input), [first, late])
        let view = try TemporalHistory.occurrenceTimeline(input)
        XCTAssertEqual(view.known, [late, first])
        XCTAssertEqual(view.known[0].sourceID, "camera:desk")
        XCTAssertEqual(view.known[0].confidence, try Confidence(0.9))
        XCTAssertEqual(input, [late, first])
    }

    func testUnknownOccurrenceIsNotReplacedByObservedTime() throws {
        let unknown = try observation(2, occurred: nil, observed: 50)
        let known = try observation(1, occurred: 100, observed: 200)
        let view = try TemporalHistory.occurrenceTimeline([unknown, known])
        XCTAssertEqual(view.known, [known])
        XCTAssertEqual(view.unknown, [unknown])
        XCTAssertNil(view.unknown[0].timestamps.occurredAt)
    }

    func testEqualOccurrenceUsesObservationThenJournalSequence() throws {
        let first = try observation(1, occurred: 100, observed: 200)
        let second = try observation(2, occurred: 100, observed: 200)
        let earlierObservation = try observation(3, occurred: 100, observed: 150)
        XCTAssertEqual(try TemporalHistory.occurrenceTimeline([second, first, earlierObservation]).known,
                       [earlierObservation, first, second])
    }

    func testRejectsDuplicateAndInvalidSequences() throws {
        let first = try observation(1, occurred: 100, observed: 200)
        XCTAssertThrowsError(try TemporalHistory.journalOrder([first, first]))
        XCTAssertThrowsError(try observation(0, occurred: 100, observed: 200))
        XCTAssertThrowsError(try observation(-1, occurred: 100, observed: 200))
    }

    func testValidatesInstantsAndIANAZones() throws {
        for invalid in [Double.nan, .infinity, -.infinity, -62_135_596_801, 253_402_300_800] {
            XCTAssertThrowsError(try instant(invalid))
        }
        XCTAssertEqual(try UTCInstant(date: Date(timeIntervalSince1970: 123.5)), try instant(123.5))
        XCTAssertNoThrow(try IANATimeZone(identifier: "Etc/UTC"))
        for invalid in ["", "GMT+0200", "Not/A_Zone"] {
            XCTAssertThrowsError(try IANATimeZone(identifier: invalid))
        }
    }

    func testHalfOpenOpenEndedAndEmptyIntervals() throws {
        let interval = try InstantInterval(start: instant(100), end: instant(200))
        XCTAssertTrue(interval.contains(try instant(100)))
        XCTAssertFalse(interval.contains(try instant(200)))
        XCTAssertFalse(interval.contains(try instant(99)))
        XCTAssertTrue(try InstantInterval(start: instant(100), end: nil).contains(instant(1_000)))
        XCTAssertFalse(try InstantInterval(start: instant(100), end: instant(100)).contains(instant(100)))
        XCTAssertThrowsError(try InstantInterval(start: instant(200), end: instant(100)))
    }

    func testInjectedClockSeparatesWallTimeAndElapsedDuration() throws {
        let zone = try IANATimeZone(identifier: "Europe/Paris")
        let before = try FixedClock(instant: instant(1_000), timeZone: zone, elapsed: .seconds(10))
        let wallMovedBack = try FixedClock(instant: instant(500), timeZone: zone, elapsed: .seconds(20))
        XCTAssertLessThan(wallMovedBack.now(), before.now())
        XCTAssertGreaterThan(wallMovedBack.monotonicElapsed(), before.monotonicElapsed())
        XCTAssertEqual(wallMovedBack.timezone(), zone)
        XCTAssertThrowsError(try FixedClock(instant: instant(0), timeZone: zone, elapsed: .seconds(-1)))
        let system = SystemClock(timeZone: zone)
        XCTAssertNoThrow(try system.now())
        let elapsed = system.monotonicElapsed()
        XCTAssertGreaterThanOrEqual(system.monotonicElapsed(), elapsed)
    }

    func testRejectsInvalidProvenance() throws {
        let times = try observation(1, occurred: nil, observed: 1).timestamps
        for source in ["", "  ", "camera\nsecret", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try JournalObservation(id: UUID(), sequence: 1, timestamps: times,
                sourceID: source, confidence: Confidence(0.5)))
        }
    }
}
