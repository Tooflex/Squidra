import Foundation
import SquidraDomain

/// Closed input shape is enforced by the host before decoding. No identity,
/// scope, model configuration, execution permit or resume command is accepted.
public struct RunHTTPSubmission: Decodable, Sendable {
    public let schemaVersion: String, question: String, entityId: UUID, intent: String
}
public struct RunHTTPAcceptance: Encodable, Sendable {
    public let schemaVersion = "1"
    public let runId: String, threadId: String, requestId: String, traceId: String
    public let status: String, events: String
    public init(binding: AGUIRunBinding, traceID: UUID) {
        runId = binding.runID.uuidString.lowercased();threadId = binding.threadID.uuidString.lowercased()
        requestId = binding.requestID.uuidString.lowercased();traceId = traceID.uuidString.lowercased()
        status = "/api/v1/runs/"+runId;events = status+"/events"
    }
}
/// Diagnostic runtime checkpoint, separate from publication completion. It is
/// never a dispatch permit or proof that an answer was durably published.
public struct RunHTTPRuntimeStatus: Encodable, Sendable {
    public let state: String, traceId: String, version: String, activeMilliseconds: String
    public let steps: Int, calls: Int
    public init(state: String, traceID: UUID, version: Int64, activeMilliseconds: Int64, steps: Int, calls: Int) {
        self.state = state;traceId = traceID.uuidString.lowercased();self.version = String(version)
        self.activeMilliseconds = String(activeMilliseconds);self.steps = steps;self.calls = calls
    }
}
public struct RunHTTPStatus: Encodable, Sendable {
    public let schemaVersion = "1", protocolVersion = AGUIEvent.protocolVersion
    public let runId: String, threadId: String, requestId: String, publicationPhase: String
    public let outputReady: Bool, terminal: Bool, leaseExpired: Bool
    public let nextSequence: String, minimumRetainedSequence: String, expiresAt: String
    public let runtime: RunHTTPRuntimeStatus?
    public init(_ status: RunPublicationStatus, runtime: RunHTTPRuntimeStatus?) throws {
        let info = status.stream
        runId = info.binding.runID.uuidString.lowercased();threadId = info.binding.threadID.uuidString.lowercased();requestId = info.binding.requestID.uuidString.lowercased()
        publicationPhase = status.phase.rawValue;outputReady = status.phase == .succeeded;terminal = info.isTerminal;leaseExpired = status.leaseExpired
        nextSequence = String(info.nextSequence);minimumRetainedSequence = String(info.minimumRetainedSequence);expiresAt = try RFC3339.format(info.expiresAt)
        self.runtime = runtime
    }
}
