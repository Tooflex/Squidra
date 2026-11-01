import Foundation
import SquidraMemory

/// Host must supply a qualified counter for every model that its router can
/// select, including message framing. No heuristic tokenizer is silently used.
public protocol MemoryTokenCounter: Sendable {
    func tokensForUserMessage(_ content: String) throws -> Int
}

/// Constructible only by the checked provider; has no system-role content.
public struct MemoryContext: Sendable {
    public let message: ModelMessage?
    public let memoryIDs: [UUID], sourceIDs: [UUID]
    public let tokenCount: Int
}

public struct MemoryContextProvider: Sendable {
    private let store: any MemoryStore
    private let counter: any MemoryTokenCounter
    private let maximumTokens: Int, maximumEntries: Int
    public init(store: any MemoryStore, counter: any MemoryTokenCounter,
                maximumTokens: Int = 2048, maximumEntries: Int = 16) throws {
        guard (1...16_384).contains(maximumTokens), (1...64).contains(maximumEntries) else { throw MemoryError.invalidQuery }
        self.store = store; self.counter = counter; self.maximumTokens = maximumTokens; self.maximumEntries = maximumEntries
    }
    public func context(actorID: UUID, subjectIDs: Set<UUID>, question: String,
                        deadline: ContinuousClock.Instant) async throws -> MemoryContext {
        let query = try MemoryQuery(actorID: actorID, subjectIDs: subjectIDs, text: question)
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw MemoryError.deadlineExceeded }
        let candidates = try await withThrowingTaskGroup(of: [MemoryRecord].self) { group in
            group.addTask { try await store.retrieve(query, deadline: deadline) }
            group.addTask {
                try await ContinuousClock().sleep(until: deadline)
                throw MemoryError.deadlineExceeded
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw MemoryError.invalidResult }
            return result
        }
        guard candidates.count <= query.maximumCandidates,
              Set(candidates.map(\.id)).count == candidates.count else { throw MemoryError.invalidResult }
        // Revalidate even an incorrectly implemented/untrusted adapter's results.
        let permitted = candidates.filter(query.permits)
        var ranked: [(MemoryRecord, Int)] = permitted.map { ($0, query.relevance($0)) }.filter { $0.1 > 0 }
        ranked.sort { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            return left.0.id.uuidString < right.0.id.uuidString
        }
        var selected: [MemoryRecord] = [], text: String?, tokens = 0
        for (candidate, _) in ranked {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw MemoryError.deadlineExceeded }
            if selected.count == maximumEntries { break }
            let proposed = selected + [candidate]
            let encoded = try Self.encode(proposed)
            guard encoded.utf8.count <= 65_536 else { continue }
            let count = try counter.tokensForUserMessage(encoded)
            guard count > 0, count <= 1_000_000 else { throw MemoryError.invalidTokenCount }
            if count <= maximumTokens { selected = proposed; text = encoded; tokens = count }
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw MemoryError.deadlineExceeded }
        return MemoryContext(message: text.map { ModelMessage(role: .user, content: $0) },
            memoryIDs: selected.map(\.id), sourceIDs: Set(selected.flatMap(\.sourceIDs)).sorted { $0.uuidString < $1.uuidString }, tokenCount: tokens)
    }
    private static func encode(_ records: [MemoryRecord]) throws -> String {
        let value: [String: Any] = ["schemaVersion": "1", "kind": "untrusted_memory_data", "memories": records.map {
            ["memoryID": $0.id.uuidString.lowercased(), "subjectID": $0.subjectID.uuidString.lowercased(),
             "sourceIDs": $0.sourceIDs.map { $0.uuidString.lowercased() }, "text": $0.text] as [String: Any]
        }]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
