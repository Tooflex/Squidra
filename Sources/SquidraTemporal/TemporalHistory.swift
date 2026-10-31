import Foundation
import SquidraDomain

public enum TemporalHistoryError: Error, Equatable, Sendable {
    case invalidSequence
    case invalidSource
    case duplicateSequence
}

/// Temporal metadata only; append-only storage and event payloads are SQD-016.
public struct JournalObservation: Equatable, Sendable {
    public let id: UUID
    public let sequence: Int64
    public let timestamps: ObservationTimestamps
    public let sourceID: String
    public let confidence: Confidence

    public init(id: UUID, sequence: Int64, timestamps: ObservationTimestamps,
                sourceID: String, confidence: Confidence) throws {
        guard sequence > 0 else { throw TemporalHistoryError.invalidSequence }
        guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourceID.utf8.count <= 256,
              !sourceID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TemporalHistoryError.invalidSource
        }
        self.id = id
        self.sequence = sequence
        self.timestamps = timestamps
        self.sourceID = sourceID
        self.confidence = confidence
    }
}

public struct OccurrenceTimeline: Equatable, Sendable {
    public let known: [JournalObservation]
    /// Unknown occurrences stay in journal order, outside the dated timeline.
    public let unknown: [JournalObservation]
}

public enum TemporalHistory {
    /// Replay order never depends on occurrence, observation, or recording time.
    public static func journalOrder(_ observations: [JournalObservation]) throws -> [JournalObservation] {
        guard Set(observations.map(\.sequence)).count == observations.count else {
            throw TemporalHistoryError.duplicateSequence
        }
        return observations.sorted { $0.sequence < $1.sequence }
    }

    /// A derived view; late evidence does not rewrite the underlying journal.
    /// Equal occurrences are ordered by observation time, then journal sequence.
    public static func occurrenceTimeline(_ observations: [JournalObservation]) throws -> OccurrenceTimeline {
        let journal = try journalOrder(observations)
        let known = journal.filter { $0.timestamps.occurredAt != nil }.sorted { lhs, rhs in
            if lhs.timestamps.occurredAt != rhs.timestamps.occurredAt {
                // Both values are known by construction; avoid inventing a fallback timestamp.
                if let left = lhs.timestamps.occurredAt, let right = rhs.timestamps.occurredAt {
                    return left < right
                }
            }
            if lhs.timestamps.observedAt != rhs.timestamps.observedAt {
                return lhs.timestamps.observedAt < rhs.timestamps.observedAt
            }
            return lhs.sequence < rhs.sequence
        }
        return OccurrenceTimeline(known: known, unknown: journal.filter { $0.timestamps.occurredAt == nil })
    }
}
