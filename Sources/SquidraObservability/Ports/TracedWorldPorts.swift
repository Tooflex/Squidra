import Foundation
import SquidraWorld

public struct TracedWorldRepository: WorldRepository {
    private let repository: any WorldRepository
    public init(_ repository: any WorldRepository) { self.repository = repository }
    public func append(_ event: WorldEventDraft, expectedVersion: Int64, idempotencyKey: String,
                       deadline: ContinuousClock.Instant) async throws -> JournalAppend {
        guard let session = TraceSession.current else { return try await repository.append(event,expectedVersion:expectedVersion,idempotencyKey:idempotencyKey,deadline:deadline) }
        return try await session.withSpan(.journal) {
            let result = try await repository.append(event,expectedVersion:expectedVersion,idempotencyKey:idempotencyKey,deadline:deadline)
            if let usage = try? TraceUsage(worldSequence:result.event.sequence,eventID:result.event.draft.id) { await session.recordUsage(usage) }
            return result
        }
    }
    public func page(actorID: UUID, afterSequence: Int64 = 0, cursor: JournalCursor? = nil, limit: Int = 64,
                     deadline: ContinuousClock.Instant) async throws -> JournalPage {
        guard let session = TraceSession.current else { return try await repository.page(actorID:actorID,afterSequence:afterSequence,cursor:cursor,limit:limit,deadline:deadline) }
        return try await session.withSpan(.journal) {
            let result = try await repository.page(actorID:actorID,afterSequence:afterSequence,cursor:cursor,limit:limit,deadline:deadline)
            if result.throughSequence > 0,let usage = try? TraceUsage(worldSequence:result.throughSequence) { await session.recordUsage(usage) }
            return result
        }
    }
}
public struct TracedWorldProjector: WorldProjector {
    private let projector: any WorldProjector
    public init(_ projector: any WorldProjector) { self.projector = projector }
    public func apply(_ event: JournalEvent) async throws {
        guard let session = TraceSession.current else { return try await projector.apply(event) }
        try await session.withSpan(.projection) {
            try await projector.apply(event)
            if let usage = try? TraceUsage(worldSequence:event.sequence,eventID:event.draft.id) { await session.recordUsage(usage) }
        }
    }
    public func checkpoint() async throws -> ProjectionCheckpoint {
        guard let session = TraceSession.current else { return try await projector.checkpoint() }
        return try await session.withSpan(.projection) {
            let result = try await projector.checkpoint()
            if let sequence = result.lastSequence,let usage = try? TraceUsage(worldSequence:sequence) { await session.recordUsage(usage) }
            return result
        }
    }
}
