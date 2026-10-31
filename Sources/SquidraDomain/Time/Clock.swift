/// SRS §3.1 ClockPort. Wall instants and monotonic elapsed durations are
/// separate APIs, so a wall-clock adjustment cannot consume a run budget.
public protocol Clock: Sendable {
    func now() throws -> UTCInstant
    func timezone() -> IANATimeZone
    func monotonicElapsed() -> Duration
}

/// Immutable clock fixture; no sleeps or ambient timezone in deterministic tests.
public struct FixedClock: Clock {
    private let instant: UTCInstant
    private let zone: IANATimeZone
    private let elapsed: Duration

    public init(instant: UTCInstant, timeZone: IANATimeZone,
                elapsed: Duration = .zero) throws {
        guard elapsed >= .zero else {
            throw TemporalValidationError.negativeElapsedDuration
        }
        self.instant = instant
        self.zone = timeZone
        self.elapsed = elapsed
    }

    public func now() -> UTCInstant { instant }
    public func timezone() -> IANATimeZone { zone }
    public func monotonicElapsed() -> Duration { elapsed }
}
