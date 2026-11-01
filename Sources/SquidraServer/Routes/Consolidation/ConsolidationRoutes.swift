import Foundation
import Hummingbird
import SquidraDomain
import SquidraMemory

/// Private memory review only. Does not execute tools, publish world facts,
/// expose archive import, or authorize an external action.
enum ConsolidationRoutes {
    static func mount(_ router: Router<BoundaryContext>, store: any ConsolidationStore) {
        router.get("/api/v1/consolidations/:journal") { _, context in
            do {
                let archive = try await load(context, store: store)
                let workspace = try await archive.workspace(), proposals = await workspace.allProposals()
                return try response(Index(journalId: archive.id, journalVersion: archive.version,
                                          proposals: proposals.map(Summary.init)))
            } catch { throw mapped(error) }
        }
        router.get("/api/v1/consolidations/:journal/proposals/:proposal") { _, context in
            do {
                let archive = try await load(context, store: store)
                return try await preview(archive, id: proposalID(context))
            } catch { throw mapped(error) }
        }
        router.post("/api/v1/consolidations/:journal/proposals/:proposal/decision") { request, context in
            do {
                guard request.headers[values: .contentType].count == 1,
                      request.headers[.contentType]?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw HTTPError(.badRequest) }
                let body = try await request.body.collect(upTo: 1024), decision = try parse(Data(body.readableBytesView))
                var archive = try await load(context, store: store)
                guard archive.version == decision.journalVersion else { throw HTTPError(.conflict) }
                let id = try proposalID(context), workspace = try await archive.workspace()
                guard await workspace.proposal(id: id) != nil else { throw HTTPError(.notFound) }
                // Identity and review time are host-owned; input cannot forge them.
                _ = try await archive.review(id: id, expectedVersion: decision.proposalVersion, authenticatedActorID: archive.actorID,
                                             reviewerID: archive.actorID, approve: decision.approve, at: UTCInstant(date: Date()))
                try await store.save(archive, deadline: .now.advanced(by: .seconds(4)))
                return try await preview(archive, id: id)
            } catch { throw mapped(error) }
        }
    }
    private static func load(_ context: BoundaryContext, store: any ConsolidationStore) async throws -> ConsolidationArchive {
        guard let actor = context.actorID else { throw HTTPError(.unauthorized) }
        guard let id = UUID(uuidString: context.parameters.get("journal") ?? "") else { throw HTTPError(.badRequest) }
        guard let archive = try await store.load(id: id, deadline: .now.advanced(by: .seconds(4))),
              archive.actorID == actor, archive.id == id else { throw HTTPError(.notFound) }
        return archive
    }
    private static func proposalID(_ context: BoundaryContext) throws -> UUID {
        guard let id = UUID(uuidString: context.parameters.get("proposal") ?? "") else { throw HTTPError(.badRequest) }
        return id
    }
    private struct Index: Encodable {
        let schemaVersion = "1"
        let journalId: UUID, journalVersion: Int64
        let proposals: [Summary]
    }
    private struct Summary: Encodable {
        let id: UUID, subjectId: UUID
        let version: Int64, predicate: String, state: String, critical: Bool
        init(_ proposal: FactProposal) {
            id = proposal.id; subjectId = proposal.candidate.subjectID; version = proposal.version
            predicate = proposal.candidate.predicate; state = label(proposal.state); critical = proposal.critical
        }
    }
    private struct Evidence: Encodable {
        let memoryId: UUID, sourceIds: [UUID], quotation: String, originalText: String
    }
    private struct Preview: Encodable {
        let schemaVersion = "1"
        let journalId: UUID, journalVersion: Int64, proposal: Summary
        let value: String, validFrom: String, validUntil: String?
        let sourceIds: [UUID], conflictingProposalIds: [UUID], evidence: [Evidence]
        let reviewerId: UUID?, reviewedAt: String?
    }
    private static func preview(_ archive: ConsolidationArchive, id: UUID) async throws -> Response {
        let workspace = try await archive.workspace()
        guard let proposal = await workspace.proposal(id: id) else { throw HTTPError(.notFound) }
        var evidence: [Evidence] = []
        for (memoryID, quote) in proposal.candidate.quotations.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let original = await workspace.original(id: memoryID) else { throw ConsolidationStoreError.invalidArchive }
            evidence.append(Evidence(memoryId: memoryID, sourceIds: original.sourceIDs, quotation: quote, originalText: original.text))
        }
        return try response(Preview(journalId: archive.id, journalVersion: archive.version, proposal: Summary(proposal), value: proposal.candidate.value,
                                    validFrom: RFC3339.format(proposal.candidate.validTime.start), validUntil: proposal.candidate.validTime.end.map(RFC3339.format),
                                    sourceIds: proposal.sourceIDs, conflictingProposalIds: proposal.conflictingProposalIDs, evidence: evidence,
                                    reviewerId: proposal.review?.reviewerID, reviewedAt: proposal.review.map { try RFC3339.format($0.reviewedAt) }))
    }
    private static func label(_ state: FactProposalState) -> String {
        switch state { case .pending: "pending"; case .approved: "approved"; case .rejected: "rejected"; case .conflicted: "conflicted" }
    }
    private static func response<T: Encodable>(_ value: T) throws -> Response {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 1048576 else { throw HTTPError(.serviceUnavailable) }
        return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(bytes: data)))
    }
    private struct Decision { let journalVersion: Int64, proposalVersion: Int64, approve: Bool }
    /// Closed four-string grammar, canonical bounded decimal versions; duplicate
    /// keys, escapes, identity, evidence or command replacements are rejected.
    private static func parse(_ data: Data) throws -> Decision {
        guard data.count <= 1024, let raw = String(data: data, encoding: .utf8) else { throw HTTPError(.badRequest) }
        let whitespace = CharacterSet(charactersIn: " \t\r\n")
        let text = raw.trimmingCharacters(in: whitespace)
        guard text.first == "{", text.last == "}" else { throw HTTPError(.badRequest) }
        let pairs = text.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
        guard pairs.count == 4 else { throw HTTPError(.badRequest) }
        var fields: [String: String] = [:]
        for pair in pairs {
            let parts = pair.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw HTTPError(.badRequest) }
            func word(_ part: Substring) throws -> String {
                let token = part.trimmingCharacters(in: whitespace)
                guard token.first == "\"", token.last == "\"", token.count >= 3 else { throw HTTPError(.badRequest) }
                let word = String(token.dropFirst().dropLast())
                guard word.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw HTTPError(.badRequest) }
                return word
            }
            guard try fields.updateValue(word(parts[1]), forKey: word(parts[0])) == nil else { throw HTTPError(.badRequest) }
        }
        func version(_ name: String) throws -> Int64 {
            guard let text = fields[name], let value = Int64(text), (0...512).contains(value), String(value) == text else { throw HTTPError(.badRequest) }
            return value
        }
        guard Set(fields.keys) == ["schemaVersion", "journalVersion", "proposalVersion", "decision"], fields["schemaVersion"] == "1",
              let decision = fields["decision"], ["approved", "rejected"].contains(decision) else { throw HTTPError(.badRequest) }
        return try Decision(journalVersion: version("journalVersion"), proposalVersion: version("proposalVersion"), approve: fields["decision"] == "approved")
    }
    private static func mapped(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? any HTTPResponseError { return error }
        if let error = error as? ConsolidationError {
            switch error {
            case .conflict, .staleReview: return HTTPError(.conflict)
            case .forbidden: return HTTPError(.forbidden)
            default: return HTTPError(.serviceUnavailable)
            }
        }
        if let error = error as? ConsolidationStoreError, error == .conflict { return HTTPError(.conflict) }
        return HTTPError(.serviceUnavailable)
    }
}
