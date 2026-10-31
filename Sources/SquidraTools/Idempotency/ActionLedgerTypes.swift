import Foundation

public enum ActionLedgerError: Error, Equatable, Sendable {
    case invalidCommand, invalidOutcome, conflict, versionConflict, notFound, unavailable, corruptRecord, reconciliationRequired
}
public enum ActionStatus: String, Codable, Sendable { case reserved, pending, succeeded, failed, unknown
    public var isFinal: Bool { self == .succeeded || self == .failed }
}
public enum ActionFailureCode: String, Codable, Sendable { case providerFailure, invalidOutput, timedOut, cancelled, notApplied }

/// Internal durable result. Base64 Codable storage preserves the exact payload
/// bytes across JSONB formatting; decoded payload is still untrusted tool data.
public struct ActionResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let status: ActionStatus
    public let payload: Data?
    public let callID: UUID?
    public let failure: ActionFailureCode?
    public let toolIdentifier: String?
    private init(status: ActionStatus, payload: Data?, callID: UUID?, failure: ActionFailureCode?, toolIdentifier: String?) {
        schemaVersion = 1; self.status = status; self.payload = payload; self.callID = callID; self.failure = failure; self.toolIdentifier = toolIdentifier
    }
    public static func succeeded(_ result: UntrustedToolResult, for tool: ToolID) throws -> Self {
        guard result.tool == tool else { throw ActionLedgerError.invalidOutcome }
        let value = Self(status: .succeeded, payload: result.payload, callID: result.callID, failure: nil, toolIdentifier: tool.identifier)
        try value.validate(); return value
    }
    public static func failed(_ code: ActionFailureCode) -> Self { Self(status: .failed, payload: nil, callID: nil, failure: code, toolIdentifier: nil) }
    public func validate() throws {
        guard schemaVersion == 1,
              (status == .succeeded && payload != nil && callID != nil && failure == nil && payload!.count <= 1_048_576 && toolIdentifier != nil)
              || (status == .failed && payload == nil && callID == nil && failure != nil && toolIdentifier == nil) else { throw ActionLedgerError.invalidOutcome }
    }
}

public struct ActionRecord: Sendable, Equatable {
    public let id: UUID
    public let command: ActionCommand
    public let status: ActionStatus
    public let version: Int64
    public let result: ActionResult?
    public let providerReference: String?
    public init(id: UUID, command: ActionCommand, status: ActionStatus, version: Int64,
                result: ActionResult?, providerReference: String?) throws {
        guard version > 0, status.isFinal == (result != nil), result.map({ $0.status == status }) ?? true,
              providerReference.map({ !$0.isEmpty && $0.utf8.count <= 2_048 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) ?? true else {
            throw ActionLedgerError.corruptRecord
        }
        try result?.validate()
        guard result?.status != .succeeded || result?.toolIdentifier == command.tool.identifier else { throw ActionLedgerError.corruptRecord }
        self.id = id; self.command = command; self.status = status; self.version = version
        self.result = result; self.providerReference = providerReference
    }
}
public struct ActionReservation: Sendable { public let record: ActionRecord; public let created: Bool
    public init(record: ActionRecord, created: Bool) { self.record = record; self.created = created }
}
public protocol ActionLedgerStore: Sendable {
    func reserve(_ command: ActionCommand, deadline: ContinuousClock.Instant) async throws -> ActionReservation
    func load(actorID: UUID, id: UUID, deadline: ContinuousClock.Instant) async throws -> ActionRecord
    func update(_ record: ActionRecord, to status: ActionStatus, result: ActionResult?, providerReference: String?, deadline: ContinuousClock.Instant) async throws -> ActionRecord
}
public struct ActionDispatchPermit: Sendable {
    public let record: ActionRecord // internal initializer; only a successful claim creates it
}
public enum ActionPreparation: Sendable {
    case dispatch(ActionDispatchPermit)
    case replay(ActionRecord)
    case inProgress(ActionRecord)
    case reconciliationRequired(ActionRecord)
}
