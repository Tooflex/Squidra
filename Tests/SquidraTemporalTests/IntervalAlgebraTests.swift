import SquidraDomain
import SquidraTemporal
import XCTest

final class IntervalAlgebraTests: XCTestCase {
    private func interval(_ start: Double, _ end: Double?) throws -> InstantInterval {
        try InstantInterval(start: UTCInstant(secondsSince1970: start),
            end: end.map { try UTCInstant(secondsSince1970: $0) })
    }

    func testFixedTruthTable() throws {
        // start/end lhs, start/end rhs, before, overlaps, during
        let rows: [(Double, Double?, Double, Double?, Bool, Bool, Bool)] = [
            (0, 2, 0, 2, false, true, true),       // equality
            (1, 2, 0, 3, false, true, true),       // containment
            (0, 3, 1, 2, false, true, false),      // contains, inverse
            (0, 2, 1, 3, false, true, false),      // partial overlap
            (1, 3, 0, 2, false, true, false),      // symmetric intersection
            (0, 1, 1, 2, true, false, false),      // adjacent: excluded end
            (1, 2, 0, 1, false, false, false),
            (0, 1, 2, 3, true, false, false),      // positive gap
            (2, 3, 0, 1, false, false, false),
            (0, 2, 0, 3, false, true, true),       // shared start
            (1, 3, 0, 3, false, true, true),       // shared end
            (0, nil, 1, nil, false, true, false),  // no sentinel infinity
            (1, nil, 0, nil, false, true, true),
            (1, 2, 0, nil, false, true, true),
            (1, nil, 0, 2, false, true, false),
            (0, 1, 1, nil, true, false, false),
            (0, 0, 10, 20, false, false, true),    // empty subset
            (10, 20, 0, 0, false, false, false),
            (0, 0, 1, 1, false, false, true),
        ]
        for (a, b, c, d, before, overlaps, during) in rows {
            let lhs = try interval(a, b), rhs = try interval(c, d)
            let label = "\(a)..\(String(describing: b)) vs \(c)..\(String(describing: d))"
            XCTAssertEqual(IntervalAlgebra.before(lhs, rhs), before, label)
            XCTAssertEqual(IntervalAlgebra.overlaps(lhs, rhs), overlaps, label)
            XCTAssertEqual(IntervalAlgebra.during(lhs, rhs), during, label)
        }
    }

    func testHalfOpenMembershipAndEmptyIntervals() throws {
        let finite = try interval(0, 1), empty = try interval(1, 1)
        XCTAssertTrue(finite.contains(try UTCInstant(secondsSince1970: 0)))
        XCTAssertFalse(finite.contains(try UTCInstant(secondsSince1970: 1)))
        XCTAssertTrue(IntervalAlgebra.isEmpty(empty))
        XCTAssertFalse(empty.contains(try UTCInstant(secondsSince1970: 1)))
        XCTAssertFalse(IntervalAlgebra.isEmpty(try interval(1, nil)))
    }

    func testRelationLawsAcrossFiniteAndUnboundedFixtures() throws {
        var fixtures: [InstantInterval] = []
        for start in -2...2 {
            for end in start...3 { fixtures.append(try interval(Double(start), Double(end))) }
            fixtures.append(try interval(Double(start), nil))
        }
        for lhs in fixtures {
            XCTAssertTrue(IntervalAlgebra.during(lhs, lhs))
            XCTAssertFalse(IntervalAlgebra.before(lhs, lhs))
            for rhs in fixtures {
                XCTAssertEqual(IntervalAlgebra.overlaps(lhs, rhs), IntervalAlgebra.overlaps(rhs, lhs))
                if IntervalAlgebra.before(lhs, rhs) {
                    XCTAssertFalse(IntervalAlgebra.overlaps(lhs, rhs))
                    XCTAssertFalse(IntervalAlgebra.before(rhs, lhs))
                }
                if !IntervalAlgebra.isEmpty(lhs) && IntervalAlgebra.during(lhs, rhs) {
                    XCTAssertTrue(IntervalAlgebra.overlaps(lhs, rhs))
                }
                for third in fixtures where IntervalAlgebra.during(lhs, rhs) && IntervalAlgebra.during(rhs, third) {
                    XCTAssertTrue(IntervalAlgebra.during(lhs, third))
                }
            }
        }
    }

    func testInvalidBoundsReturnTypedErrors() {
        XCTAssertThrowsError(try interval(2, 1)) { XCTAssertEqual($0 as? TemporalValidationError, .reversedInterval) }
        for invalid in [Double.nan, .infinity, -.infinity, 253_402_300_800, -62_135_596_801] {
            XCTAssertThrowsError(try interval(invalid, nil)) { XCTAssertEqual($0 as? TemporalValidationError, .invalidInstant) }
            XCTAssertThrowsError(try interval(0, invalid)) { XCTAssertEqual($0 as? TemporalValidationError, .invalidInstant) }
        }
    }
}
