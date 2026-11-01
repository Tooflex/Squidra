import Foundation

public enum MemoryError: Error, Equatable, Sendable {
    case invalidRecord, invalidQuery, invalidResult, deadlineExceeded, invalidTokenCount, budgetTooSmall
}
public enum MemorySensitivity: Sendable { case modelAllowed, privateOnly, secret }

/// Classification and source references are supplied by trusted ingestion, not a model.
public struct MemoryRecord: Sendable {
    public let id: UUID, actorID: UUID, subjectID: UUID
    public let sourceIDs: [UUID]
    public let sensitivity: MemorySensitivity
    public let text: String
    public init(id: UUID = UUID(), actorID: UUID, subjectID: UUID, sourceIDs: [UUID],
                sensitivity: MemorySensitivity, text: String) throws {
        guard !sourceIDs.isEmpty, sourceIDs.count <= 16, Set(sourceIDs).count == sourceIDs.count,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 8192,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw MemoryError.invalidRecord }
        self.id = id; self.actorID = actorID; self.subjectID = subjectID
        self.sourceIDs = sourceIDs.sorted { $0.uuidString < $1.uuidString }
        self.sensitivity = sensitivity; self.text = text
    }
}

public struct MemoryQuery: Sendable {
    public let actorID: UUID, subjectIDs: Set<UUID>
    public let terms: Set<String>
    public let maximumCandidates: Int
    public init(actorID: UUID, subjectIDs: Set<UUID>, text: String, maximumCandidates: Int = 64) throws {
        guard subjectIDs.count <= 32, text.utf8.count <= 4096, (1...256).contains(maximumCandidates) else { throw MemoryError.invalidQuery }
        let words = Self.words(text)
        guard !words.isEmpty, words.count <= 256 else { throw MemoryError.invalidQuery }
        self.actorID = actorID; self.subjectIDs = subjectIDs; self.terms = words
        self.maximumCandidates = maximumCandidates
    }
    public func permits(_ record: MemoryRecord) -> Bool {
        record.actorID == actorID && subjectIDs.contains(record.subjectID) && record.sensitivity == .modelAllowed
    }
    public func relevance(_ record: MemoryRecord) -> Int { terms.intersection(Self.words(record.text)).count }
    private static func words(_ value: String) -> Set<String> {
        Set(value.precomposedStringWithCanonicalMapping.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
}

/// Filter actor, subjects and sensitivity BEFORE retrieval/ranking. Consumers
/// recheck returned rows before injecting them; returned content is untrusted.
public protocol MemoryStore: Sendable {
    func retrieve(_ query: MemoryQuery, deadline: ContinuousClock.Instant) async throws -> [MemoryRecord]
}

/// Bounded reference adapter, useful for offline/embedded hosts. No persistence
/// or semantic embedding accuracy is claimed by this lexical implementation.
public actor InMemoryMemoryStore: MemoryStore {
    private let records: [MemoryRecord]
    public init(records: [MemoryRecord]) throws {
        guard records.count <= 1024, Set(records.map(\.id)).count == records.count else { throw MemoryError.invalidRecord }
        self.records = records
    }
    public func retrieve(_ query: MemoryQuery, deadline: ContinuousClock.Instant) throws -> [MemoryRecord] {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw MemoryError.deadlineExceeded }
        // Unauthorized rows never participate in scoring or top-k truncation.
        let candidates = records.filter(query.permits).map { ($0, query.relevance($0)) }.filter { $0.1 > 0 }
        let ranked = candidates.sorted { $0.1 == $1.1 ? $0.0.id.uuidString < $1.0.id.uuidString : $0.1 > $1.1 }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw MemoryError.deadlineExceeded }
        return ranked.prefix(query.maximumCandidates).map(\.0)
    }
}
