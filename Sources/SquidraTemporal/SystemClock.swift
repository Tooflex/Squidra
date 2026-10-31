import Foundation
import SquidraDomain

public struct SystemClock: SquidraDomain.Clock {
    private let zone: IANATimeZone
    private let start: ContinuousClock.Instant

    public init(timeZone: IANATimeZone) {
        self.zone = timeZone
        self.start = ContinuousClock.now
    }

    public func now() throws -> UTCInstant { try UTCInstant(date: Date()) }
    public func timezone() -> IANATimeZone { zone }
    public func monotonicElapsed() -> Duration { start.duration(to: .now) }
}
