import Foundation
import SquidraWorld

public enum WorldRecoveryError: Error, Equatable, Sendable {
    case invalidConfiguration, unsupportedProjection, invalidSnapshot, eventLimit, deadlineExceeded, unavailable
}
public struct WorldRecoveryLimits: Sendable {
    public let pageSize: Int, maximumEvents: Int
    public let timeout: Duration
    public init(pageSize: Int = 64, maximumEvents: Int = 10_000, timeout: Duration = .seconds(30)) throws {
        guard (1...128).contains(pageSize), (1...100_000).contains(maximumEvents), timeout > .zero, timeout <= .seconds(300) else {
            throw WorldRecoveryError.invalidConfiguration
        }
        self.pageSize = pageSize; self.maximumEvents = maximumEvents; self.timeout = timeout
    }
}
public struct WorldRecoveryReport: Equatable, Sendable {
    public let actorID: UUID
    public let startSequence: Int64, capturedThroughSequence: Int64, projectedThroughSequence: Int64
    public let replayedEvents: Int
}
/// Replays a bounded immutable actor snapshot, including an empty-cache rebuild.
/// It neither deletes projections nor edits the durable source journal.
public struct WorldProjectionRecovery: Sendable {
    private let actorID: UUID, repository: any WorldRepository, projector: any WorldProjector
    private let limits: WorldRecoveryLimits
    public init(actorID: UUID, repository: any WorldRepository, projector: any WorldProjector,
                limits: WorldRecoveryLimits = try! WorldRecoveryLimits()) {
        self.actorID = actorID; self.repository = repository; self.projector = projector; self.limits = limits
    }
    public func recover() async throws -> WorldRecoveryReport {
        let deadline = ContinuousClock.now.advanced(by:limits.timeout)
        do {
            return try await withThrowingTaskGroup(of:WorldRecoveryReport.self) { group in
                group.addTask { try await replay(deadline:deadline) }
                group.addTask { try await Task.sleep(until:deadline); throw WorldRecoveryError.deadlineExceeded }
                defer { group.cancelAll() }
                guard let report = try await group.next() else { throw WorldRecoveryError.unavailable }; return report
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as WorldRecoveryError { throw error }
        catch { throw WorldRecoveryError.unavailable }
    }
    private func replay(deadline: ContinuousClock.Instant) async throws -> WorldRecoveryReport {
        try Task.checkCancellation()
        let initial = try await projector.checkpoint()
        guard initial.projectionVersion == 1 else { throw WorldRecoveryError.unsupportedProjection }
        let start = initial.lastSequence ?? 0
        var last = start, captured: Int64?, cursor: JournalCursor?, replayed = 0
        var seen: Set<UUID> = []
        repeat {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw WorldRecoveryError.deadlineExceeded }
            let page = try await repository.page(actorID:actorID,afterSequence:cursor == nil ? start : 0,cursor:cursor,limit:limits.pageSize,
                deadline:min(deadline,ContinuousClock.now.advanced(by:.seconds(4))))
            guard page.events.count <= limits.pageSize, page.throughSequence >= last,
                  captured.map({ $0 == page.throughSequence }) ?? true else { throw WorldRecoveryError.invalidSnapshot }
            captured = page.throughSequence
            // Check the whole page before applying any event from a malformed page.
            var checked = last
            for event in page.events {
                guard event.draft.actorID == actorID, event.sequence > checked, event.sequence <= page.throughSequence,
                      seen.insert(event.draft.id).inserted else { throw WorldRecoveryError.invalidSnapshot }
                checked = event.sequence
            }
            if let next = page.next {
                guard !page.events.isEmpty, next.actorID == actorID, next.afterSequence == checked,
                      next.throughSequence == page.throughSequence, checked < page.throughSequence else { throw WorldRecoveryError.invalidSnapshot }
            } else { guard checked == page.throughSequence else { throw WorldRecoveryError.invalidSnapshot } }
            for event in page.events {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw WorldRecoveryError.deadlineExceeded }
                guard replayed < limits.maximumEvents else { throw WorldRecoveryError.eventLimit }
                try await projector.apply(event)
                replayed += 1; last = event.sequence
            }
            cursor = page.next
        } while cursor != nil
        let final = try await projector.checkpoint()
        guard let captured, final.projectionVersion == 1, (final.lastSequence ?? 0) >= captured else { throw WorldRecoveryError.invalidSnapshot }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw WorldRecoveryError.deadlineExceeded }
        return WorldRecoveryReport(actorID:actorID,startSequence:start,capturedThroughSequence:captured,
            projectedThroughSequence:final.lastSequence ?? 0,replayedEvents:replayed)
    }
}
