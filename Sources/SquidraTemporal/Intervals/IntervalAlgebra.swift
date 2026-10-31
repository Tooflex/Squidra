import SquidraDomain

/// Set-based relations over validated half-open UTC intervals.
///
/// `before` includes adjacency: [0, 1) is before [1, 2). `overlaps`
/// means a nonempty intersection, symmetrically, rather than Allen's strict
/// directional relation. `during` is inclusive set containment, including
/// equality. An empty interval is during every interval (empty subset), but
/// never before or overlapping another interval. These relations describe
/// known intervals; they do not interpret unknown observation timestamps.
public enum IntervalAlgebra {
    public static func isEmpty(_ interval: InstantInterval) -> Bool {
        interval.end == interval.start
    }

    public static func before(_ lhs: InstantInterval, _ rhs: InstantInterval) -> Bool {
        guard !isEmpty(lhs), !isEmpty(rhs), let end = lhs.end else { return false }
        return end <= rhs.start
    }

    public static func overlaps(_ lhs: InstantInterval, _ rhs: InstantInterval) -> Bool {
        guard !isEmpty(lhs), !isEmpty(rhs) else { return false }
        return (lhs.end.map { rhs.start < $0 } ?? true)
            && (rhs.end.map { lhs.start < $0 } ?? true)
    }

    public static func during(_ lhs: InstantInterval, _ rhs: InstantInterval) -> Bool {
        if isEmpty(lhs) { return true }
        guard !isEmpty(rhs), lhs.start >= rhs.start else { return false }
        guard let rhsEnd = rhs.end else { return true }
        guard let lhsEnd = lhs.end else { return false }
        return lhsEnd <= rhsEnd
    }
}
