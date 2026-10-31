import Crypto
import Foundation

public enum ApprovalError: Error, Equatable, Sendable {
    case invalidRequest, denied, notFound, conflict, expired, notApproved, corruptRecord, unavailable
}
public struct ApprovalBinding: Equatable, Sendable {
    public let actorID: UUID, runID: UUID, ledgerID: UUID
    /// SQUIDRA-ACTION-1 fingerprint: actor/tool/version/target/arguments/scope.
    public let commandHash: Data
    public init(actorID: UUID, runID: UUID, ledgerID: UUID, commandHash: Data) throws {
        guard commandHash.count == 32 else { throw ApprovalError.invalidRequest }
        self.actorID = actorID; self.runID = runID; self.ledgerID = ledgerID; self.commandHash = commandHash
    }
    public func digest(expiresAtMilliseconds: Int64) -> Data {
        let hash = commandHash.map { String(format:"%02x",$0) }.joined()
        let bytes = "SQUIDRA-APPROVAL-1\n"+actorID.uuidString.lowercased()+"\n"+runID.uuidString.lowercased()+"\n"
            + ledgerID.uuidString.lowercased()+"\n"+hash+"\n"+String(expiresAtMilliseconds)
        return Data(SHA256.hash(data:Data(bytes.utf8)))
    }
}
public enum ApprovalDecision: String, Codable, Sendable { case pending, approved, denied, expired, withdrawn }
public enum ApprovalResponse: Sendable { case approve, deny, withdraw
    public var decision: ApprovalDecision { switch self { case .approve: .approved;case .deny: .denied;case .withdraw: .withdrawn } }
}
public struct ApprovalRecord: Equatable, Sendable {
    public let id: UUID
    public let binding: ApprovalBinding
    public let requestedAtMilliseconds: Int64, expiresAtMilliseconds: Int64
    public let digest: Data
    public let decision: ApprovalDecision
    public let approverID: UUID?
    public let decidedAtMilliseconds: Int64?
    public let version: Int64
    public init(id: UUID, binding: ApprovalBinding, requestedAtMilliseconds: Int64, expiresAtMilliseconds: Int64,
                decision: ApprovalDecision = .pending, approverID: UUID? = nil, decidedAtMilliseconds: Int64? = nil, version: Int64 = 1) throws {
        let lower: Int64 = -62_135_596_800_000, upper: Int64 = 253_402_300_800_000
        guard requestedAtMilliseconds >= lower, expiresAtMilliseconds < upper,
              expiresAtMilliseconds > requestedAtMilliseconds,
              expiresAtMilliseconds-requestedAtMilliseconds <= 600_000, version > 0 else { throw ApprovalError.corruptRecord }
        if decision == .pending {
            guard approverID == nil, decidedAtMilliseconds == nil else { throw ApprovalError.corruptRecord }
        } else {
            guard let decidedAtMilliseconds, decidedAtMilliseconds >= requestedAtMilliseconds, decidedAtMilliseconds < upper,
                  decision == .expired || approverID != nil,
                  decision != .approved || decidedAtMilliseconds < expiresAtMilliseconds,
                  decision != .expired || decidedAtMilliseconds >= expiresAtMilliseconds else { throw ApprovalError.corruptRecord }
        }
        self.id = id; self.binding = binding; self.requestedAtMilliseconds = requestedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds; digest = binding.digest(expiresAtMilliseconds:expiresAtMilliseconds)
        self.decision = decision; self.approverID = approverID; self.decidedAtMilliseconds = decidedAtMilliseconds; self.version = version
    }
}
public struct ApprovalObservation: Sendable {
    public let record: ApprovalRecord
    public let observedAtMilliseconds: Int64
    public init(record: ApprovalRecord, observedAtMilliseconds: Int64) { self.record = record; self.observedAtMilliseconds = observedAtMilliseconds }
}
/// SRS ApprovalPort. All timestamps come from the host clock or storage, not a client.
public protocol ApprovalStore: Sendable {
    func request(_ binding: ApprovalBinding, nowMilliseconds: Int64, ttlMilliseconds: Int64, deadline: ContinuousClock.Instant) async throws -> ApprovalRecord
    func load(actorID: UUID, id: UUID, deadline: ContinuousClock.Instant) async throws -> ApprovalObservation
    func resolve(_ record: ApprovalRecord, response: ApprovalResponse, approverID: UUID, nowMilliseconds: Int64, deadline: ContinuousClock.Instant) async throws -> ApprovalRecord
}
/// Non-Codable, no public initializer. Issued only after durable verification.
public struct VerifiedApproval: Sendable {
    public let id: UUID
    public let binding: ApprovalBinding
    public let digest: Data
    public let expiresAtMilliseconds: Int64
}
public protocol ApprovalAuthorizer: Sendable {
    func verify(actorID: UUID, id: UUID, binding: ApprovalBinding, deadline: ContinuousClock.Instant) async throws -> VerifiedApproval
}
