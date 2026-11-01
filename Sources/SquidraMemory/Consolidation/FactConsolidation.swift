import Foundation
import SquidraDomain

public enum ConsolidationError: Error, Equatable, Sendable {
    case invalidInput, invalidSource, capacityExceeded, conflict, staleReview, forbidden
}

/// Host-owned single-valued predicate. Candidates cannot lower its criticality.
public struct FactPredicate: Equatable, Sendable {
    public let name: String
    public let critical: Bool
    public init(name: String, critical: Bool) throws {
        guard !name.isEmpty, name.utf8.count <= 64,
              name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [95, 46].contains($0) }) else {
            throw ConsolidationError.invalidInput
        }
        self.name = name; self.critical = critical
    }
}

/// Untrusted extraction, never a world fact or permission. Quotes must match
/// the original memory; even a matching quote does not prove its interpretation.
public struct FactCandidate: Equatable, Sendable {
    public let subjectID: UUID
    public let predicate: String, value: String
    public let validTime: InstantInterval
    public let quotations: [UUID: String]
    public init(subjectID: UUID, predicate: String, value: String,
                validTime: InstantInterval, quotations: [UUID: String]) throws {
        guard !predicate.isEmpty, predicate.utf8.count <= 64,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 2048, !value.contains("\0"),
              !quotations.isEmpty, quotations.count <= 16,
              quotations.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 && !$0.contains("\0") }),
              validTime.end.map({ $0 > validTime.start }) ?? true else { throw ConsolidationError.invalidInput }
        self.subjectID = subjectID; self.predicate = predicate; self.value = value
        self.validTime = validTime; self.quotations = quotations
    }
}

public enum FactProposalState: Sendable { case pending, conflicted, approved, rejected }
public struct FactReview: Sendable {
    public let reviewerID: UUID
    public let approved: Bool
    public let reviewedAt: UTCInstant
}
public struct FactProposal: Sendable {
    public let id: UUID, actorID: UUID
    public let candidate: FactCandidate
    public let critical: Bool
    public let sourceIDs: [UUID]
    public fileprivate(set) var version: Int64 = 0
    public fileprivate(set) var state: FactProposalState = .pending
    public fileprivate(set) var conflictingProposalIDs: [UUID] = []
    public fileprivate(set) var review: FactReview?
}

/// Bounded offline workspace. Originals are immutable; there is no journal
/// write/delete port and no model, network or autonomous approval. The host must
/// authenticate the reviewer before calling review. These APIs are not HTTP
/// authorization, and this in-memory adapter does not claim restart durability.
public actor FactConsolidation {
    private let actorID: UUID
    private let originals: [UUID: MemoryRecord]
    private let predicates: [String: FactPredicate]
    private var proposals: [UUID: FactProposal] = [:]
    private var batches: [UUID: (candidates: [FactCandidate], ids: [UUID])] = [:]

    public init(actorID: UUID, records: [MemoryRecord], predicates: [FactPredicate]) throws {
        guard records.count <= 256, Set(records.map(\.id)).count == records.count,
              records.reduce(0, { $0 + $1.text.utf8.count }) <= 262144,
              records.allSatisfy({ $0.actorID == actorID && $0.sensitivity != .secret }),
              !predicates.isEmpty, predicates.count <= 32,
              Set(predicates.map(\.name)).count == predicates.count else { throw ConsolidationError.invalidInput }
        self.actorID = actorID
        self.originals = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        self.predicates = Dictionary(uniqueKeysWithValues: predicates.map { ($0.name, $0) })
    }

    /// Atomic bounded batch with an immutable idempotency key. Source records
    /// and event IDs are retained; duplicates never count as independent proof.
    public func propose(batchID: UUID, candidates: [FactCandidate]) throws -> [FactProposal] {
        guard !candidates.isEmpty, candidates.count <= 32 else { throw ConsolidationError.invalidInput }
        return try propose(batchID: batchID, candidates: candidates, proposalIDs: candidates.map { _ in UUID() })
    }

    // Journal replay retains exact identities; arbitrary callers cannot replace
    // existing proposals or inject a pre-approved state.
    internal func propose(batchID: UUID, candidates: [FactCandidate], proposalIDs: [UUID]) throws -> [FactProposal] {
        try Task.checkCancellation()
        guard !candidates.isEmpty, candidates.count <= 32 else { throw ConsolidationError.invalidInput }
        if let previous = batches[batchID] {
            guard previous.candidates == candidates else { throw ConsolidationError.conflict }
            return previous.ids.compactMap { proposals[$0] }
        }
        guard batches.count < 256, proposals.count + candidates.count <= 256 else { throw ConsolidationError.capacityExceeded }
        guard proposalIDs.count == candidates.count, Set(proposalIDs).count == proposalIDs.count,
              proposalIDs.allSatisfy({ proposals[$0] == nil }) else { throw ConsolidationError.invalidInput }
        var pending: [FactProposal] = []
        for (index, candidate) in candidates.enumerated() {
            guard let predicate = predicates[candidate.predicate] else { throw ConsolidationError.invalidInput }
            var sources = Set<UUID>()
            for (memoryID, quote) in candidate.quotations {
                guard let memory = originals[memoryID], memory.subjectID == candidate.subjectID,
                      memory.text.contains(quote) else { throw ConsolidationError.invalidSource }
                sources.formUnion(memory.sourceIDs)
            }
            guard sources.count <= 16 else { throw ConsolidationError.invalidSource }
            pending.append(FactProposal(id: proposalIDs[index], actorID: actorID, candidate: candidate,
                                        critical: predicate.critical, sourceIDs: sources.sorted(by: Self.ordered)))
        }
        // Validate every input before mutating state. Compare against all prior
        // proposals, including rejected ones: rejection does not erase evidence.
        var next = proposals
        for proposal in pending { next[proposal.id] = proposal }
        let all = Array(next.values)
        for proposal in all {
            let conflicts = all.filter { other in
                other.id != proposal.id && other.candidate.subjectID == proposal.candidate.subjectID &&
                other.candidate.predicate == proposal.candidate.predicate &&
                other.candidate.value != proposal.candidate.value &&
                Self.overlaps(other.candidate.validTime, proposal.candidate.validTime)
            }.map(\.id).sorted(by: Self.ordered)
            var updated = proposal
            if updated.conflictingProposalIDs != conflicts {
                updated.conflictingProposalIDs = conflicts
                updated.state = .conflicted
                updated.version += 1
            }
            next[proposal.id] = updated
        }
        proposals = next
        batches[batchID] = (candidates, pending.map(\.id))
        return pending.compactMap { proposals[$0.id] }
    }

    /// All promotions require an exact-version explicit review, including
    /// noncritical proposals. Contradictions cannot be waived by a review.
    public func review(id: UUID, expectedVersion: Int64, authenticatedActorID: UUID,
                       reviewerID: UUID, approve: Bool, at: UTCInstant) throws -> FactProposal {
        try Task.checkCancellation()
        guard authenticatedActorID == actorID else { throw ConsolidationError.forbidden }
        guard var proposal = proposals[id] else { throw ConsolidationError.invalidInput }
        guard proposal.version == expectedVersion else { throw ConsolidationError.staleReview }
        guard proposal.conflictingProposalIDs.isEmpty else { throw ConsolidationError.conflict }
        guard proposal.state == .pending else { throw ConsolidationError.staleReview }
        proposal.review = FactReview(reviewerID: reviewerID, approved: approve, reviewedAt: at)
        proposal.state = approve ? .approved : .rejected
        proposal.version += 1
        proposals[id] = proposal
        return proposal
    }

    public func proposal(id: UUID) -> FactProposal? { proposals[id] }
    public func original(id: UUID) -> MemoryRecord? { originals[id] }

    /// A reviewed fact is a private memory, never world evidence. Rechecks the
    /// current state so a later contradiction withdraws it from future exports.
    public func promotedMemory(id: UUID) throws -> MemoryRecord {
        guard let proposal = proposals[id], proposal.state == .approved,
              proposal.review?.approved == true, proposal.conflictingProposalIDs.isEmpty else {
            throw ConsolidationError.forbidden
        }
        let start = proposal.candidate.validTime.start.secondsSince1970
        let end = proposal.candidate.validTime.end.map { String($0.secondsSince1970) } ?? "unbounded"
        return try MemoryRecord(id: proposal.id, actorID: actorID, subjectID: proposal.candidate.subjectID,
                                sourceIDs: proposal.sourceIDs, sensitivity: .privateOnly,
                                text: "Reviewed proposal \(proposal.id): \(proposal.candidate.predicate) = \(proposal.candidate.value) (UTC seconds [\(start), \(end))).")
    }

    private static func ordered(_ a: UUID, _ b: UUID) -> Bool { a.uuidString < b.uuidString }
    private static func overlaps(_ a: InstantInterval, _ b: InstantInterval) -> Bool {
        (a.end.map { b.start < $0 } ?? true) && (b.end.map { a.start < $0 } ?? true)
    }
}
