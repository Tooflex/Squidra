import Foundation
import SquidraDomain

public enum ConsolidationStoreError: Error, Equatable, Sendable {
    case invalidArchive, conflict, unavailable, timeout, cancelled
}

/// Replayable version-1 private journal. State and approval are recomputed from
/// commands, never accepted from serialized proposal status fields.
public struct ConsolidationArchive: Sendable {
    private var envelope: Envelope
    public var actorID: UUID { envelope.actorID }
    public var id: UUID { envelope.id }
    public var version: Int64 { Int64(envelope.commands.count) }
    public init(id: UUID = UUID(), actorID: UUID, records: [MemoryRecord], predicates: [FactPredicate]) throws {
        _ = try FactConsolidation(actorID: actorID, records: records, predicates: predicates)
        envelope = Envelope(schemaVersion: 1, id: id, actorID: actorID,
                            records: records.map(MemoryDTO.init), predicates: predicates.map(PredicateDTO.init), commands: [])
        _ = try encoded()
    }
    public func encoded() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= 2_097_152, envelope.commands.count <= 512,
              let text = String(data: data, encoding: .utf8) else { throw ConsolidationStoreError.invalidArchive }
        return text
    }
    /// Storage uses this exact predecessor for append-only CAS. Genesis has none.
    public func predecessor() throws -> String? {
        guard !envelope.commands.isEmpty else { return nil }
        var previous = self; previous.envelope.commands.removeLast()
        return try previous.encoded()
    }
    public static func decode(_ text: String) async throws -> Self {
        guard text.utf8.count <= 2_097_152 else { throw ConsolidationStoreError.invalidArchive }
        do {
            let value = try JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
            guard value.schemaVersion == 1, value.commands.count <= 512 else { throw ConsolidationStoreError.invalidArchive }
            let result = Self(envelope: value)
            // Canonical text rejects unknown fields, alternate encodings and
            // omitted/null ambiguities; the SQL column preserves this exact text.
            guard try result.encoded() == text else { throw ConsolidationStoreError.invalidArchive }
            _ = try await result.workspace()
            return result
        } catch is CancellationError { throw CancellationError() }
        catch { throw ConsolidationStoreError.invalidArchive }
    }
    private init(envelope: Envelope) { self.envelope = envelope }
    public func workspace() async throws -> FactConsolidation {
        let workspace = try FactConsolidation(actorID: actorID, records: envelope.records.map { try $0.record(actorID) },
                                             predicates: envelope.predicates.map { try FactPredicate(name: $0.name, critical: $0.critical) })
        for command in envelope.commands {
            try Task.checkCancellation()
            switch command {
            case .batch(let batch):
                let result = try await workspace.propose(batchID: batch.id, candidates: batch.candidates.map { try $0.candidate() }, proposalIDs: batch.proposalIDs)
                guard result.map(\.id) == batch.proposalIDs else { throw ConsolidationStoreError.invalidArchive }
            case .review(let review):
                _ = try await workspace.review(id: review.id, expectedVersion: review.version, authenticatedActorID: actorID,
                                               reviewerID: review.reviewerID, approve: review.approve, at: UTCInstant(secondsSince1970: review.at))
            }
        }
        return workspace
    }
    public mutating func propose(batchID: UUID, candidates: [FactCandidate]) async throws -> [FactProposal] {
        let workspace = try await workspace()
        let rows = try await workspace.propose(batchID: batchID, candidates: candidates)
        // An exact replay returns current state without appending another command.
        if envelope.commands.contains(where: { if case .batch(let batch) = $0 { return batch.id == batchID }; return false }) { return rows }
        var next = self
        next.envelope.commands.append(.batch(BatchDTO(id: batchID, candidates: candidates.map(CandidateDTO.init), proposalIDs: rows.map(\.id))))
        _ = try next.encoded(); self = next
        return rows
    }
    public mutating func review(id: UUID, expectedVersion: Int64, authenticatedActorID: UUID,
                                reviewerID: UUID, approve: Bool, at: UTCInstant) async throws -> FactProposal {
        let workspace = try await workspace()
        let result = try await workspace.review(id: id, expectedVersion: expectedVersion, authenticatedActorID: authenticatedActorID,
                                               reviewerID: reviewerID, approve: approve, at: at)
        var next = self
        next.envelope.commands.append(.review(ReviewDTO(id: id, version: expectedVersion, reviewerID: reviewerID, approve: approve, at: at.secondsSince1970)))
        _ = try next.encoded(); self = next
        return result
    }
}

public protocol ConsolidationStore: Sendable {
    func save(_ archive: ConsolidationArchive, deadline: ContinuousClock.Instant) async throws
    func load(id: UUID, deadline: ContinuousClock.Instant) async throws -> ConsolidationArchive?
}

private struct Envelope: Codable, Sendable {
    let schemaVersion: Int, id: UUID, actorID: UUID
    let records: [MemoryDTO], predicates: [PredicateDTO]
    var commands: [CommandDTO]
}
private enum CommandDTO: Codable, Sendable { case batch(BatchDTO), review(ReviewDTO) }
private struct BatchDTO: Codable, Sendable { let id: UUID; let candidates: [CandidateDTO]; let proposalIDs: [UUID] }
private struct ReviewDTO: Codable, Sendable { let id: UUID; let version: Int64; let reviewerID: UUID; let approve: Bool; let at: Double }
private struct PredicateDTO: Codable, Sendable {
    let name: String, critical: Bool
    init(_ value: FactPredicate) { name = value.name; critical = value.critical }
}
private struct MemoryDTO: Codable, Sendable {
    let id: UUID, subjectID: UUID
    let sourceIDs: [UUID], sensitivity: String, text: String
    init(_ value: MemoryRecord) {
        id = value.id; subjectID = value.subjectID; sourceIDs = value.sourceIDs; text = value.text
        sensitivity = value.sensitivity == .modelAllowed ? "modelAllowed" : "privateOnly"
    }
    func record(_ actorID: UUID) throws -> MemoryRecord {
        guard ["modelAllowed", "privateOnly"].contains(sensitivity) else { throw ConsolidationStoreError.invalidArchive }
        return try MemoryRecord(id: id, actorID: actorID, subjectID: subjectID, sourceIDs: sourceIDs,
                                sensitivity: sensitivity == "modelAllowed" ? .modelAllowed : .privateOnly, text: text)
    }
}
private struct CandidateDTO: Codable, Sendable {
    let subjectID: UUID
    let predicate: String, value: String
    let start: Double, end: Double?
    let quotes: [String: String]
    init(_ value: FactCandidate) {
        subjectID = value.subjectID; predicate = value.predicate; self.value = value.value
        start = value.validTime.start.secondsSince1970; end = value.validTime.end?.secondsSince1970
        quotes = Dictionary(uniqueKeysWithValues: value.quotations.map { ($0.key.uuidString, $0.value) })
    }
    func candidate() throws -> FactCandidate {
        var citations: [UUID: String] = [:]
        for (key, value) in quotes {
            guard let id = UUID(uuidString: key), id.uuidString == key else { throw ConsolidationStoreError.invalidArchive }
            citations[id] = value
        }
        return try FactCandidate(subjectID: subjectID, predicate: predicate, value: value,
                                 validTime: InstantInterval(start: UTCInstant(secondsSince1970: start), end: end.map { try UTCInstant(secondsSince1970: $0) }), quotations: citations)
    }
}
