/// Confidence in an observation or fact. Unknown confidence must be modeled
/// separately; it must not be encoded as NaN or silently converted to zero.
public struct Confidence: Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case outOfRange
    }

    public let value: Double

    /// Accepts finite values in the closed interval [0, 1] (ADR-008).
    public init(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw ValidationError.outOfRange
        }
        self.value = value
    }
}
