import Foundation

public enum WatchError: Error, Equatable, Sendable { case invalidRequest, notFound, conflict, capacityExceeded, unavailable }
public enum WatchStatus: String, Sendable { case active, cancelled, fulfilled }
public struct WatchIntention: Equatable, Sendable {
    public let id: UUID, actorID: UUID, entityID: UUID
    public let status: WatchStatus
    public let afterSequence: Int64
    public init(id: UUID, actorID: UUID, entityID: UUID, status: WatchStatus, afterSequence: Int64) throws {
        guard afterSequence >= 0 else { throw WatchError.invalidRequest }
        self.id = id; self.actorID = actorID; self.entityID = entityID; self.status = status; self.afterSequence = afterSequence
    }
}
public struct WatchNotification: Equatable, Sendable {
    public let intentionID: UUID, sourceEventID: UUID, notificationEventID: UUID
    public let created: Bool
    public init(intentionID: UUID, sourceEventID: UUID, notificationEventID: UUID, created: Bool) {
        self.intentionID = intentionID; self.sourceEventID = sourceEventID; self.notificationEventID = notificationEventID; self.created = created
    }
}
/// Host-only persistence port; models must use the authorized Action Gateway.
/// Watches complete on their first qualified movement after registration.
public protocol IntentionStore: Sendable {
    func watch(entityID: UUID, key: String, deadline: ContinuousClock.Instant) async throws -> WatchIntention
    func load(id: UUID, deadline: ContinuousClock.Instant) async throws -> WatchIntention?
    func cancel(id: UUID, deadline: ContinuousClock.Instant) async throws -> WatchIntention
    func deliver(intentionID: UUID, eventID: UUID, deadline: ContinuousClock.Instant) async throws -> WatchNotification?
}
