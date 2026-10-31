import Foundation
import SquidraDomain

/// Actor/run-bound pagination position, not an authentication token or a grant.
public struct AGUIResumeCursor: Equatable, Sendable {
    public let actorID: UUID, runID: UUID
    public let afterSequence: Int64
    public init(actorID: UUID, runID: UUID, afterSequence: Int64) throws {
        guard afterSequence >= 0 else { throw AGUIError.invalidCursor }
        self.actorID = actorID;self.runID = runID;self.afterSequence = afterSequence
    }
    private struct Wire: Codable { let schemaVersion: String,actorId: String,runId: String,afterSequence: String }
    public func encoded() throws -> String {
        let wire = Wire(schemaVersion:"1",actorId:actorID.uuidString.lowercased(),runId:runID.uuidString.lowercased(),afterSequence:String(afterSequence))
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(wire).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }
    public static func decode(_ token: String) throws -> Self {
        do {
            guard !token.isEmpty,token.utf8.count <= 2048,
                  token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,95].contains($0) }) else { throw AGUIError.invalidCursor }
            var base64 = token.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
            base64 += String(repeating:"=",count:(4-base64.utf8.count%4)%4)
            guard let data = Data(base64Encoded:base64) else { throw AGUIError.invalidCursor }
            _ = try JSONDocument(data,maximumBytes:1536)
            let wire = try JSONDecoder().decode(Wire.self,from:data)
            guard wire.schemaVersion == "1",let actor = UUID(uuidString:wire.actorId),let run = UUID(uuidString:wire.runId),
                  let sequence = Int64(wire.afterSequence),String(sequence) == wire.afterSequence else { throw AGUIError.invalidCursor }
            let cursor = try Self(actorID:actor,runID:run,afterSequence:sequence)
            guard try cursor.encoded() == token else { throw AGUIError.invalidCursor }
            return cursor
        } catch { throw AGUIError.invalidCursor }
    }
}
public struct AGUIReplayBounds: Sendable {
    public let actorID: UUID, runID: UUID
    public let minimumRetainedSequence: Int64, nextSequence: Int64
    public init(actorID: UUID, runID: UUID, minimumRetainedSequence: Int64, nextSequence: Int64) throws {
        guard minimumRetainedSequence >= 1,nextSequence >= minimumRetainedSequence,nextSequence <= AGUIStreamValidator.maximumEvents+1 else { throw AGUIError.invalidCursor }
        self.actorID = actorID;self.runID = runID;self.minimumRetainedSequence = minimumRetainedSequence;self.nextSequence = nextSequence
    }
    /// Authenticated actor/run must already be bound by the storage adapter.
    public func afterSequence(for token: String?) throws -> Int64 {
        let cursor = try token.map(AGUIResumeCursor.decode)
        if let cursor { guard cursor.actorID == actorID,cursor.runID == runID else { throw AGUIError.invalidCursor } }
        let after = cursor?.afterSequence ?? 0
        guard after < nextSequence else { throw AGUIError.invalidCursor }
        guard after >= minimumRetainedSequence-1 else { throw AGUIError.cursorOutsideRetention }
        return after
    }
}
public struct AGUIStreamRecord: Sendable {
    public let binding: AGUIRunBinding
    public let sequence: Int64
    public let event: AGUIEvent
    public init(binding: AGUIRunBinding, sequence: Int64, event: AGUIEvent) throws {
        guard binding == event.binding else { throw AGUIError.scopeMismatch }
        guard sequence >= 1,sequence <= AGUIStreamValidator.maximumEvents else { throw AGUIError.invalidSequence }
        self.binding = binding;self.sequence = sequence;self.event = event
    }
    public func encodedSSE() throws -> Data {
        // Producer JSON is compact. Refuse multiline storage bytes rather than
        // letting them create SSE control lines through a future restore path.
        guard !event.json.contains(10),!event.json.contains(13) else { throw AGUIError.invalidEvent }
        let cursor = try AGUIResumeCursor(actorID:binding.actorID,runID:binding.runID,afterSequence:sequence).encoded()
        return Data("id: \(cursor)\ndata: \(String(decoding:event.json,as:UTF8.self))\n\n".utf8)
    }
    public static let heartbeat = Data(": keepalive\n\n".utf8)
}
