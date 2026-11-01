import Foundation
import SquidraTools

/// Private untrusted tool bytes, bound to the original invocation. This is not
/// factual evidence or a permit to dispatch; recovery must validate both again.
public struct StoredReadRunToolResult: Sendable {
    public let actorID: UUID,runID: UUID,requestID: UUID,callID: UUID
    public let executionVersion: Int64
    public let commandFingerprint: String,toolIdentifier: String
    public let payload: Data
    public init(actorID: UUID,runID: UUID,requestID: UUID,callID: UUID,executionVersion: Int64,
                commandFingerprint: String,toolIdentifier: String,payload: Data) {
        self.actorID = actorID;self.runID = runID;self.requestID = requestID;self.callID = callID
        self.executionVersion = executionVersion;self.commandFingerprint = commandFingerprint
        self.toolIdentifier = toolIdentifier;self.payload = payload
    }
}
public protocol ReadRunToolResultStore: Sendable {
    func save(snapshot: RunSnapshot,requestID: UUID,command: ActionCommand,result: UntrustedToolResult,deadline: ContinuousClock.Instant) async throws
    func load(runID: UUID,deadline: ContinuousClock.Instant) async throws -> StoredReadRunToolResult?
}
