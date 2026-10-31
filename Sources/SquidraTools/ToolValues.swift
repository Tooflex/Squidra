import Foundation
import SquidraDomain

public typealias ToolID = SquidraDomain.ToolID
public typealias ToolRisk = SquidraDomain.ToolRisk
public typealias ToolIdempotency = SquidraDomain.ToolIdempotency
public typealias ToolDefinition = SquidraDomain.ToolDefinition

public enum ToolError: String, Error, Sendable {
    case invalidDefinition = "TOOL_INVALID_DEFINITION", duplicate = "TOOL_DUPLICATE", unknownTool = "TOOL_NOT_FOUND"
    case unsupportedSchema = "TOOL_UNSUPPORTED_SCHEMA", invalidInput = "TOOL_INVALID_INPUT", invalidOutput = "TOOL_INVALID_OUTPUT"
    case policyDenied = "POLICY_DENIED", timedOut = "TOOL_TIMED_OUT", providerFailure = "TOOL_PROVIDER_FAILED"
    public var publicMessage: String {
        switch self {
        case .invalidDefinition, .unsupportedSchema, .duplicate: "Tool definition is unavailable."
        case .unknownTool: "Tool not found."
        case .invalidInput: "Tool input is invalid."
        case .invalidOutput: "Tool returned invalid data; no result is confirmed."
        case .policyDenied: "Tool execution is not authorized."
        case .timedOut: "Tool deadline exceeded; outcome is unconfirmed."
        case .providerFailure: "Tool failed; outcome is unconfirmed."
        }
    }
}

/// Only the host gateway in this module can mint grants after policy/approval/
/// ledger checks. No Codable conformance or public initializer can mint one.
struct ToolExecutionGrant: Sendable {
    public let actorID: UUID, runID: UUID
    public let definition: ToolDefinition
    public var tool: ToolID { definition.id }
    public let target: String
    public let input: Data
    public let scope: Set<String>
    public let idempotencyKey: String
    public let deadline: ContinuousClock.Instant
}
public struct ToolCall: Sendable {
    public let actorID: UUID, runID: UUID
    public let tool: ToolID
    public let target: String
    public let input: Data
    public let scope: Set<String>
    public let idempotencyKey: String
    public let deadline: ContinuousClock.Instant
}
public protocol ToolExecutor: Sendable {
    /// Adapter must cooperate with cancellation/deadlines. Output is untrusted.
    func execute(_ call: ToolCall) async throws -> Data
}
public struct UntrustedToolResult: Sendable {
    public enum Trust: Sendable { case untrusted }
    public let schemaVersion = "1"
    public let tool: ToolID
    public let callID: UUID
    public let trust: Trust = .untrusted
    public let payload: Data
}
