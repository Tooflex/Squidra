import Foundation
import SquidraDomain
import SquidraWorld

/// Projection query spans record only a committed watermark, never query text,
/// entity IDs, source labels or world facts. The result stays untrusted data.
public struct TracedWorldQueries: WorldStateQuery, WorldChangesQuerying {
    private let stateQuery:any WorldStateQuery,changesQuery:any WorldChangesQuerying
    public init(state:any WorldStateQuery,changes:any WorldChangesQuerying) { stateQuery = state;changesQuery = changes }
    public func state(actorID:UUID,subjectID:UUID,validAt:SquidraDomain.UTCInstant,knownAt:SquidraDomain.UTCInstant,deadline:ContinuousClock.Instant) async throws -> WorldStateSnapshot {
        guard let session = TraceSession.current else { return try await stateQuery.state(actorID:actorID,subjectID:subjectID,validAt:validAt,knownAt:knownAt,deadline:deadline) }
        return try await session.withSpan(.projection) {
            let result = try await stateQuery.state(actorID:actorID,subjectID:subjectID,validAt:validAt,knownAt:knownAt,deadline:deadline)
            if result.projectedThroughSequence > 0,let usage = try? TraceUsage(worldSequence:result.projectedThroughSequence) { await session.recordUsage(usage) }
            return result
        }
    }
    public func changes(_ query:WorldChangesQuery,cursor:WorldChangesCursor?,limit:Int,deadline:ContinuousClock.Instant) async throws -> WorldChangesPage {
        guard let session = TraceSession.current else { return try await changesQuery.changes(query,cursor:cursor,limit:limit,deadline:deadline) }
        return try await session.withSpan(.projection) {
            let result = try await changesQuery.changes(query,cursor:cursor,limit:limit,deadline:deadline)
            if result.throughSequence > 0,let usage = try? TraceUsage(worldSequence:result.throughSequence) { await session.recordUsage(usage) }
            return result
        }
    }
}
