import Foundation
import SquidraDomain

public enum RunEventStoreError: Error, Equatable, Sendable {
    case invalidRequest, notFound, conflict, expired, limitExceeded, corruptRecord, unavailable, timedOut, cancelled
}
public struct AGUIRunStreamInfo: Sendable, Equatable {
    public static let maximumRetainedBytes: Int64 = 1_048_576
    public let binding: AGUIRunBinding
    public let nextSequence: Int64, minimumRetainedSequence: Int64, retainedBytes: Int64
    public let isTerminal: Bool
    public let retentionSeconds: Int
    public let expiresAt: UTCInstant
    public init(binding: AGUIRunBinding, nextSequence: Int64, minimumRetainedSequence: Int64, retainedBytes: Int64,
                isTerminal: Bool, retentionSeconds: Int, expiresAt: UTCInstant) throws {
        guard nextSequence >= 1,nextSequence <= AGUIStreamValidator.maximumEvents+1,
              minimumRetainedSequence >= 1,minimumRetainedSequence <= nextSequence,
              (0...Self.maximumRetainedBytes).contains(retainedBytes),(1...604_800).contains(retentionSeconds),
              nextSequence <= AGUIStreamValidator.maximumEvents || isTerminal else { throw RunEventStoreError.corruptRecord }
        self.binding = binding;self.nextSequence = nextSequence;self.minimumRetainedSequence = minimumRetainedSequence
        self.retainedBytes = retainedBytes;self.isTerminal = isTerminal;self.retentionSeconds = retentionSeconds;self.expiresAt = expiresAt
    }
}
public struct AGUIRunEventPage: Sendable {
    public let info: AGUIRunStreamInfo
    public let records: [AGUIReplayRecord]
    public let throughSequence: Int64
    public let nextCursor: String?
    public let hasMore: Bool
    public init(info: AGUIRunStreamInfo, records: [AGUIReplayRecord], throughSequence: Int64, nextCursor: String?, hasMore: Bool) {
        self.info = info;self.records = records;self.throughSequence = throughSequence;self.nextCursor = nextCursor;self.hasMore = hasMore
    }
}
/// Event publication/replay only. There is no worker, model or tool-dispatch port.
/// Actor/run ownership must be verified before parsing an external cursor.
public protocol RunEventStore: Sendable {
    func create(_ binding: AGUIRunBinding, retentionSeconds: Int, deadline: ContinuousClock.Instant) async throws -> AGUIRunStreamInfo
    func append(_ binding: AGUIRunBinding, expectedNextSequence: Int64, events: [AGUIEvent], deadline: ContinuousClock.Instant) async throws -> AGUIRunStreamInfo
    func page(actorID: UUID, runID: UUID, cursor: String?, limit: Int, deadline: ContinuousClock.Instant) async throws -> AGUIRunEventPage
}
