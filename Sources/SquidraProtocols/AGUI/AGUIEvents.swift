import Foundation
import SquidraCognition
import SquidraDomain

public enum AGUIError: Error, Equatable, Sendable {
    case invalidEvent, eventTooLarge, scopeMismatch, invalidSequence, unsupportedVersion, invalidCursor, cursorOutsideRetention
}
public struct AGUIRunBinding: Equatable, Sendable {
    public let actorID: UUID, runID: UUID, threadID: UUID, requestID: UUID
    public init(actorID: UUID, runID: UUID, threadID: UUID, requestID: UUID) {
        self.actorID = actorID;self.runID = runID;self.threadID = threadID;self.requestID = requestID
    }
}
public enum AGUIEventKind: String, Sendable {
    case runStarted = "RUN_STARTED", runFinished = "RUN_FINISHED", runError = "RUN_ERROR"
    case textStart = "TEXT_MESSAGE_START", textContent = "TEXT_MESSAGE_CONTENT", textEnd = "TEXT_MESSAGE_END", groundedAnswer = "CUSTOM"
}
public enum AGUICompletion: String, Sendable { case success, cancelled }
public enum AGUIPublicFailure: String, Sendable {
    case executionFailed = "RUN_FAILED", deadlineExceeded = "RUN_DEADLINE_EXCEEDED", recoveryRequired = "RUN_RECOVERY_REQUIRED"
    var message: String {
        switch self {
        case .executionFailed: "Run failed."
        case .deadlineExceeded: "Run deadline exceeded."
        case .recoveryRequired: "Run outcome requires recovery."
        }
    }
}
/// Squidra's typed producer subset of the pinned official AG-UI 1.0 contract.
/// No rawEvent, arbitrary custom payload, model delta or exception text factory.
public struct AGUIEvent: Sendable {
    public static let protocolVersion = "1.0"
    public static let maximumBytes = 65_536
    public let binding: AGUIRunBinding
    public let kind: AGUIEventKind
    private let document: JSONDocument
    public var json: Data { document.bytes }
    internal init(binding: AGUIRunBinding, kind: AGUIEventKind, json: Data) throws {
        guard json.count <= Self.maximumBytes else { throw AGUIError.eventTooLarge }
        do {
            let document = try JSONDocument(json,maximumBytes:Self.maximumBytes)
            guard document.kind == .object,!document.containsNUL,
                  let value = try JSONSerialization.jsonObject(with:json) as? [String:Any],value["type"] as? String == kind.rawValue else { throw AGUIError.invalidEvent }
            self.binding = binding;self.kind = kind;self.document = document
        } catch let error as AGUIError { throw error }
        catch { throw AGUIError.invalidEvent }
    }
    private static func make(_ kind: AGUIEventKind, binding: AGUIRunBinding, at: UTCInstant, fields: [String:Any]) throws -> Self {
        var fields = fields
        fields["type"] = kind.rawValue
        // Host UTC clock, integer milliseconds, safely representable by JSON/JS.
        fields["timestamp"] = Int64((at.secondsSince1970 * 1000).rounded(.down))
        let bytes = try JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys,.withoutEscapingSlashes])
        return try Self(binding:binding,kind:kind,json:bytes)
    }
    public static func started(binding: AGUIRunBinding, at: UTCInstant) throws -> Self {
        try make(.runStarted,binding:binding,at:at,fields:["threadId":binding.threadID.uuidString.lowercased(),"runId":binding.runID.uuidString.lowercased(),"protocolVersion":protocolVersion])
    }
    public static func finished(binding: AGUIRunBinding, at: UTCInstant, outcome: AGUICompletion = .success) throws -> Self {
        try make(.runFinished,binding:binding,at:at,fields:["threadId":binding.threadID.uuidString.lowercased(),"runId":binding.runID.uuidString.lowercased(),"outcome":["type":outcome.rawValue]])
    }
    public static func failed(binding: AGUIRunBinding, at: UTCInstant, code: AGUIPublicFailure) throws -> Self {
        try make(.runError,binding:binding,at:at,fields:["message":code.message,"code":code.rawValue])
    }
    /// A whole validated answer is emitted after grounding; this is not raw
    /// token streaming. Materialize all four events before persisting any.
    public static func answer(_ answer: GroundedAnswer, binding: AGUIRunBinding, messageID: UUID, at: UTCInstant) throws -> [Self] {
        guard answer.actorId == binding.actorID,answer.requestId == binding.requestID else { throw AGUIError.scopeMismatch }
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let payload = try encoder.encode(answer)
        guard payload.count <= maximumBytes else { throw AGUIError.eventTooLarge }
        let value = try JSONSerialization.jsonObject(with:payload)
        let id = messageID.uuidString.lowercased()
        return try [
            make(.groundedAnswer,binding:binding,at:at,fields:["name":"squidra.grounded_answer.v1","value":value]),
            make(.textStart,binding:binding,at:at,fields:["messageId":id,"role":"assistant"]),
            make(.textContent,binding:binding,at:at,fields:["messageId":id,"delta":answer.text]),
            make(.textEnd,binding:binding,at:at,fields:["messageId":id]),
        ]
    }
}
