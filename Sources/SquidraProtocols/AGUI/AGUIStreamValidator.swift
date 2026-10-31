import Foundation
import SquidraDomain

/// Producer/replay chronology validation. It neither authorizes a request nor
/// creates an executable command or a GroundedAnswer proof from stored JSON.
public struct AGUIStreamValidator: Sendable {
    public static let maximumEvents: Int64 = 128
    private let threadID: String, runID: String
    private let binding: AGUIRunBinding?
    private var started = false
    private var openMessage: String?
    private var seenMessage = false, seenAnswer = false
    public private(set) var isTerminal = false
    public private(set) var nextSequence: Int64 = 1
    public init(binding: AGUIRunBinding) {
        self.binding = binding;threadID = binding.threadID.uuidString.lowercased();runID = binding.runID.uuidString.lowercased()
    }
    /// Official conformance fixtures use arbitrary strings, as AG-UI permits.
    internal init(threadID: String, runID: String) { self.threadID = threadID;self.runID = runID;binding = nil }
    private struct Wire: Decodable {
        let type: String, timestamp: Int64?
        let threadId: String?, runId: String?, protocolVersion: String?, messageId: String?, role: String?, delta: String?, name: String?, message: String?, code: String?
        let outcome: Outcome?
        struct Outcome: Decodable { let type: String }
    }
    /// A rejected event leaves the entire validator unchanged.
    public mutating func accept(_ json: Data, sequence: Int64) throws {
        var next = self
        try next.consume(json,sequence:sequence)
        self = next
    }
    private mutating func consume(_ json: Data, sequence: Int64) throws {
        guard sequence == nextSequence,sequence <= Self.maximumEvents,!isTerminal else { throw AGUIError.invalidSequence }
        guard json.count <= AGUIEvent.maximumBytes else { throw AGUIError.eventTooLarge }
        let object: [String:Any],wire: Wire,kind: AGUIEventKind
        do {
            let document = try JSONDocument(json,maximumBytes:AGUIEvent.maximumBytes)
            guard document.kind == .object,!document.containsNUL,
                  let value = try JSONSerialization.jsonObject(with:json) as? [String:Any],!value.values.contains(where: { $0 is NSNull }) else { throw AGUIError.invalidEvent }
            object = value;wire = try JSONDecoder().decode(Wire.self,from:json)
            guard let parsed = AGUIEventKind(rawValue:wire.type) else { throw AGUIError.invalidEvent };kind = parsed
            if let timestamp = wire.timestamp { guard (-9_007_199_254_740_991...9_007_199_254_740_991).contains(timestamp) else { throw AGUIError.invalidEvent } }
        } catch let error as AGUIError { throw error }
        catch { throw AGUIError.invalidEvent }
        guard sequence < Self.maximumEvents || kind == .runFinished || kind == .runError else { throw AGUIError.invalidSequence }
        let fields: Set<String>
        switch kind {
        case .runStarted: fields = ["threadId","runId","protocolVersion"]
        case .runFinished: fields = ["threadId","runId","outcome"]
        case .runError: fields = ["message","code"]
        case .textStart: fields = ["messageId","role"]
        case .textContent: fields = ["messageId","delta"]
        case .textEnd: fields = ["messageId"]
        case .groundedAnswer: fields = ["name","value"]
        }
        guard Set(object.keys).isSubset(of:fields.union(["type","timestamp"])) else { throw AGUIError.invalidEvent }
        func identifier(_ value: String?) throws -> String {
            guard let value,!value.isEmpty,value.utf8.count <= 128,!value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw AGUIError.invalidEvent }
            return value
        }
        if !started { guard kind == .runStarted else { throw AGUIError.invalidSequence } }
        switch kind {
        case .runStarted:
            guard !started else { throw AGUIError.invalidSequence }
            guard wire.threadId == threadID,wire.runId == runID else { throw AGUIError.scopeMismatch }
            if let version = wire.protocolVersion { guard version == AGUIEvent.protocolVersion else { throw AGUIError.unsupportedVersion } }
            started = true
        case .runFinished:
            guard openMessage == nil else { throw AGUIError.invalidSequence }
            guard wire.threadId == threadID,wire.runId == runID else { throw AGUIError.scopeMismatch }
            if let outcome = wire.outcome {
                guard AGUICompletion(rawValue:outcome.type) != nil,
                      let raw = object["outcome"] as? [String:Any],Set(raw.keys) == ["type"] else { throw AGUIError.invalidEvent }
            }
            isTerminal = true
        case .runError:
            guard openMessage == nil else { throw AGUIError.invalidSequence }
            guard let message = wire.message,message.utf8.count <= 256,wire.code.map({ $0.utf8.count <= 64 }) ?? true else { throw AGUIError.invalidEvent }
            isTerminal = true
        case .textStart:
            guard openMessage == nil,!seenMessage,wire.role == nil || wire.role == "assistant" else { throw AGUIError.invalidSequence }
            openMessage = try identifier(wire.messageId);seenMessage = true
        case .textContent:
            guard let openMessage,try identifier(wire.messageId) == openMessage,wire.delta != nil else { throw AGUIError.invalidSequence }
        case .textEnd:
            guard let openMessage,try identifier(wire.messageId) == openMessage else { throw AGUIError.invalidSequence }
            self.openMessage = nil
        case .groundedAnswer:
            guard !seenAnswer,openMessage == nil,wire.name == "squidra.grounded_answer.v1",
                  let value = object["value"] as? [String:Any],value["schemaVersion"] as? String == "1",
                  let actor = (value["actorId"] as? String).flatMap(UUID.init(uuidString:)),
                  let request = (value["requestId"] as? String).flatMap(UUID.init(uuidString:)) else { throw AGUIError.invalidEvent }
            if let binding { guard actor == binding.actorID,request == binding.requestID else { throw AGUIError.scopeMismatch } }
            seenAnswer = true
        }
        nextSequence += 1
    }
}
