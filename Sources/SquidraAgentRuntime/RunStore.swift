import Foundation

public enum RunStoreError: Error, Equatable, Sendable { case conflict, notFound, terminal, unavailable, corruptCheckpoint }

/// SDD RunStore: actor-scoped I/O, cooperative cancellation and monotonic deadline.
/// A failed/ambiguous write grants no dispatch permit; reload before recovery.
public protocol RunStore: Sendable {
    func create(_ snapshot: RunSnapshot, deadline: ContinuousClock.Instant) async throws
    func load(actorID: UUID, runID: UUID, deadline: ContinuousClock.Instant) async throws -> RunSnapshot
    func compareAndSet(_ snapshot: RunSnapshot, expectedVersion: Int64, deadline: ContinuousClock.Instant) async throws
}
