import Foundation

public enum MovementEpochError: Error, Equatable, Sendable { case invalidState, conflict, unavailable, timeout, cancelled }
/// Sealed complete input epoch. Extending history requires a different epoch;
/// callers must not present overlapping epochs as one physical movement stream.
public struct MovementEpoch: Sendable {
    public let detector: ConfirmedMovementDetector, samples: [MovementSample], origin: MovementEvidenceOrigin
    public init(detector: ConfirmedMovementDetector, samples: [MovementSample], origin: MovementEvidenceOrigin) throws {
        _ = try detector.evaluate(samples)
        self.detector = detector; self.samples = samples; self.origin = origin
    }
    public func evaluate() throws -> MovementReport { try detector.evaluate(samples) }
}
public protocol MovementEpochStore: Sendable {
    func save(_ epoch: MovementEpoch, deadline: ContinuousClock.Instant) async throws
    func load(epochID: UUID, deadline: ContinuousClock.Instant) async throws -> MovementEpoch?
}
/// Save before publication. Recover uses only stored input; callers cannot swap
/// in a new policy, origin or an incomplete source window during a retry.
public struct MovementEpochRecovery: Sendable {
    private let store: any MovementEpochStore, publisher: MovementPublisher
    public init(store: any MovementEpochStore, publisher: MovementPublisher) { self.store = store; self.publisher = publisher }
    public func submit(_ epoch: MovementEpoch, deadline: ContinuousClock.Instant) async throws -> [UUID] {
        try await store.save(epoch,deadline: deadline)
        return try await recover(epochID: epoch.detector.epochID,deadline: deadline)
    }
    public func recover(epochID: UUID, deadline: ContinuousClock.Instant) async throws -> [UUID] {
        guard let epoch = try await store.load(epochID: epochID,deadline: deadline) else { throw MovementEpochError.invalidState }
        return try await publisher.publish(epoch.evaluate(),origin: epoch.origin,deadline: deadline).map { $0.event.draft.id }
    }
}
