import SquidraDomain
import XCTest

final class RFC3339Tests: XCTestCase {
    func testOffsetsAndDayBoundaries() throws {
        for input in ["1970-01-01T00:00:00Z", "1970-01-01t00:00:00z",
                      "1970-01-01T05:30:00+05:30", "1969-12-31T16:00:00-08:00",
                      "1970-01-01T23:59:00+23:59"] {
            XCTAssertEqual(try RFC3339.parse(input).secondsSince1970, 0, input)
        }
        XCTAssertEqual(try RFC3339.format(RFC3339.parse("2024-03-01T00:15:00+01:00")),
                       "2024-02-29T23:15:00.000000Z")
    }

    func testGregorianDatesWithoutNormalization() throws {
        XCTAssertEqual(try RFC3339.format(RFC3339.parse("2000-02-29T12:00:00Z")),
                       "2000-02-29T12:00:00.000000Z")
        for date in ["1900-02-29", "2100-02-29", "2023-02-29", "2024-02-30", "2024-04-31",
                     "2024-00-01", "2024-13-01", "2024-01-00", "0000-01-01"] {
            XCTAssertThrowsError(try RFC3339.parse(date + "T00:00:00Z"), date)
        }
        // Proleptic Gregorian: no Foundation calendar reform gap.
        XCTAssertEqual(try RFC3339.format(RFC3339.parse("1582-10-10T00:00:00Z")),
                       "1582-10-10T00:00:00.000000Z")
    }

    func testProfileAndMalformedInputRejection() {
        for input in ["2024-01-01", "2024-01-01T00:00:00", "2024-01-01 00:00:00Z",
                      "2024-01-01T24:00:00Z", "2024-01-01T00:60:00Z", "2016-12-31T23:59:60Z",
                      "2024-01-01T00:00:00-00:00", "2024-01-01T00:00:00+24:00",
                      "2024-01-01T00:00:00+01:60", "2024-01-01T00:00:00+0100",
                      "2024-01-01T00:00:00.Z", "2024-01-01T00:00:00.1234567890Z",
                      "2024-01-01T00:00:00Z\n", "2024-01-01T00:00:00Zextra",
                      "２０２４-01-01T00:00:00Z", "2024-01-01T00:00:00.1",
                      String(repeating: "0", count: 10000)] {
            XCTAssertThrowsError(try RFC3339.parse(input), input.prefix(50).description)
        }
    }

    func testFractionsNegativeEpochAndRounding() throws {
        XCTAssertEqual(try RFC3339.format(RFC3339.parse("1969-12-31T23:59:59.123456Z")),
                       "1969-12-31T23:59:59.123456Z")
        XCTAssertEqual(try RFC3339.format(RFC3339.parse("1970-01-01T00:00:00.123456789Z")),
                       "1970-01-01T00:00:00.123457Z")
        XCTAssertEqual(try RFC3339.format(RFC3339.parse("1969-12-31T23:59:59.9999999Z")),
                       "1970-01-01T00:00:00.000000Z")
        XCTAssertEqual(try RFC3339.format(RFC3339.parse("1970-01-01T00:00:00+00:00")),
                       "1970-01-01T00:00:00.000000Z")
    }

    func testSupportedRangeAndOffsetOverflow() throws {
        XCTAssertEqual(try RFC3339.parse("0001-01-01T00:00:00Z").secondsSince1970, -62135596800)
        for value in ["0001-01-01T00:00:00.000000Z", "9999-12-31T23:59:59.000000Z"] {
            XCTAssertEqual(try RFC3339.format(RFC3339.parse(value)), value)
        }
        for value in ["0001-01-01T00:00:00+00:01", "9999-12-31T23:59:59-00:01",
                      "9999-12-31T23:59:59.999999999Z"] {
            XCTAssertThrowsError(try RFC3339.parse(value))
        }
    }

    func testIndependentEpochVectorsAndCanonicalStability() throws {
        for (wire, seconds) in [("2000-01-01T00:00:00Z", 946684800.0),
                                ("1900-01-01T00:00:00Z", -2208988800.0),
                                ("2024-02-29T00:00:00Z", 1709164800.0)] {
            XCTAssertEqual(try RFC3339.parse(wire).secondsSince1970, seconds)
        }
        for seconds in [-62135596800.0, -2208988800, -86400.1, -0.123456, 0, 0.999999, 1709164800.5, 253402300799] {
            let canonical = try RFC3339.format(UTCInstant(secondsSince1970: seconds))
            XCTAssertEqual(try RFC3339.format(RFC3339.parse(canonical)), canonical)
        }
    }
}
