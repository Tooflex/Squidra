import SquidraDomain
import XCTest

final class ConfidenceTests: XCTestCase {
    func testClosedIntervalBoundaries() throws {
        XCTAssertEqual(try Confidence(0).value, 0)
        XCTAssertEqual(try Confidence(1).value, 1)
    }

    func testPreservesValidConfidence() throws {
        XCTAssertEqual(try Confidence(0.85).value, 0.85)
    }

    func testRejectsValuesOutsideInterval() {
        for value in [-Double.leastNonzeroMagnitude, 1.nextUp, -1, 2] {
            XCTAssertThrowsError(try Confidence(value)) { error in
                XCTAssertEqual(error as? Confidence.ValidationError, .outOfRange)
            }
        }
    }

    func testRejectsNonFiniteValues() {
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try Confidence(value)) { error in
                XCTAssertEqual(error as? Confidence.ValidationError, .outOfRange)
            }
        }
    }
}
