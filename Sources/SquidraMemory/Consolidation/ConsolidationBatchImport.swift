import Foundation
import SquidraDomain

/// Owner-provided structured assertions, not model-authorized facts. Every
/// imported source remains private and every new proposal remains unreviewed.
public struct ConsolidationBatchImport: Sendable {
    public let journalID: UUID, batchID: UUID
    private let genesis: ConsolidationArchive
    private let candidates: [FactCandidate]
    public init(data: Data, actorID: UUID) throws {
        let document = try JSONDocument(data, maximumBytes: 1_048_576)
        guard document.kind == .object, !document.containsNUL else { throw ConsolidationError.invalidInput }
        let json = try JSONSerialization.jsonObject(with: data)
        func object(_ value: Any, keys: Set<String>) throws -> [String: Any] {
            guard let result = value as? [String: Any], Set(result.keys) == keys else { throw ConsolidationError.invalidInput }; return result
        }
        let root = try object(json, keys: ["schemaVersion", "journalId", "batchId", "records", "predicates", "candidates"])
        for (key, fields) in [("records", Set(["id", "subjectId", "sourceIds", "text"])),
                              ("predicates", Set(["name", "critical"])),
                              ("candidates", Set(["subjectId", "predicate", "value", "validFrom", "validUntil", "quotations"]))] {
            guard let entries = root[key] as? [Any] else { throw ConsolidationError.invalidInput }
            for entry in entries { _ = try object(entry, keys: fields) }
        }
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard input.schemaVersion == "1", (1...32).contains(input.candidates.count) else { throw ConsolidationError.invalidInput }
        let records = try input.records.map { try MemoryRecord(id: $0.id, actorID: actorID, subjectID: $0.subjectId, sourceIDs: $0.sourceIds, sensitivity: .privateOnly, text: $0.text) }
        let predicates = try input.predicates.map { try FactPredicate(name: $0.name, critical: $0.critical) }
        candidates = try input.candidates.map { item in
            var quotes: [UUID: String] = [:]
            for (key, quote) in item.quotations {
                guard let id = UUID(uuidString: key), quotes.updateValue(quote, forKey: id) == nil else { throw ConsolidationError.invalidInput }
            }
            return try FactCandidate(subjectID: item.subjectId, predicate: item.predicate, value: item.value,
                                     validTime: InstantInterval(start: RFC3339.parse(item.validFrom), end: item.validUntil.map(RFC3339.parse)), quotations: quotes)
        }
        journalID = input.journalId; batchID = input.batchId
        genesis = try ConsolidationArchive(id: journalID, actorID: actorID, records: records, predicates: predicates)
    }
    /// At most three CAS attempts. Exact retries preserve IDs and any later
    /// review; changed sources/batch contents conflict rather than overwrite.
    public func apply(to store: any ConsolidationStore) async throws -> (archive: ConsolidationArchive, proposals: [FactProposal]) {
        var validation = genesis
        _ = try await validation.propose(batchID: batchID, candidates: candidates) // Validate before any write.
        let original = try genesis.encoded()
        for _ in 0..<3 {
            try Task.checkCancellation()
            do {
                var archive: ConsolidationArchive
                if let existing = try await store.load(id: journalID, deadline: .now.advanced(by: .seconds(4))) {
                    guard try existing.genesisEncoded() == original else { throw ConsolidationError.conflict }
                    archive = existing
                } else {
                    try await store.save(genesis, deadline: .now.advanced(by: .seconds(4)))
                    archive = genesis
                }
                let before = archive.version
                let proposals = try await archive.propose(batchID: batchID, candidates: candidates)
                if archive.version != before { try await store.save(archive, deadline: .now.advanced(by: .seconds(4))) }
                return (archive, proposals)
            } catch ConsolidationStoreError.conflict { continue }
        }
        throw ConsolidationStoreError.conflict
    }
}
private struct Input: Decodable {
    let schemaVersion: String, journalId: UUID, batchId: UUID
    let records: [Record], predicates: [Predicate], candidates: [Candidate]
    struct Record: Decodable { let id: UUID, subjectId: UUID; let sourceIds: [UUID], text: String }
    struct Predicate: Decodable { let name: String, critical: Bool }
    struct Candidate: Decodable {
        let subjectId: UUID, predicate: String, value: String, validFrom: String, validUntil: String?
        let quotations: [String: String]
    }
}
