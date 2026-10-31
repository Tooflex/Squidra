import Crypto
import Foundation
import SquidraDomain
import SquidraWorld

public struct WorldChangesTool: ToolExecutor {
    private let world: any WorldChangesQuerying
    public init(world: any WorldChangesQuerying) { self.world = world }
    public static func definition() throws -> ToolDefinition {
        try ToolDefinition(id: ToolID(namespace: "world", name: "get_changes", version: "1.0.0"),
            capability: "world.changes.read", risk: .r0, idempotency: .readOnly, timeoutMilliseconds: 5_000,
            maximumInputBytes: 4096, maximumOutputBytes: 131_072,
            inputSchema: WorldChangesSchemas.inputSchema, outputSchema: WorldChangesSchemas.outputSchema)
    }
    public func registration() throws -> GatewayToolRegistration {
        try GatewayToolRegistration(definition: Self.definition(), surface: .bounded, executor: self,
            resolveTarget: { try Request.decode($0).target })
    }
    private struct Request: Decodable {
        let schemaVersion: String, from: String, to: String, knownAt: String
        let subjectId: UUID?, locationId: UUID?, cursor: String?
        let limit: Int
        var target: String { subjectId.map { "entity:" + $0.uuidString.lowercased() } ?? "world:changes" }
        static func decode(_ bytes: Data) throws -> Self {
            do {
                _ = try JSONDocument(bytes, maximumBytes: 4096)
                let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                guard let object, Set(object.keys).isSubset(of: ["schemaVersion","from","to","knownAt","subjectId","locationId","cursor","limit"]) else { throw ToolError.invalidInput }
                let request = try JSONDecoder().decode(Self.self, from: bytes)
                guard request.schemaVersion == "1", (1...8).contains(request.limit), request.cursor.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true else { throw ToolError.invalidInput }
                _ = try request.query(actor: UUID())
                return request
            } catch { throw ToolError.invalidInput }
        }
        func query(actor: UUID) throws -> WorldChangesQuery {
            try WorldChangesQuery(actorID: actor, from: RFC3339.parse(from), to: RFC3339.parse(to),
                knownAt: RFC3339.parse(knownAt), subjectID: subjectId, locationID: locationId)
        }
    }
    /// This digest binds query values; it is not a signature or an authorization
    /// grant. Every continuation goes through current policy and the read port.
    private static func fingerprint(_ query: WorldChangesQuery) -> String {
        let fields = [query.actorID.uuidString.lowercased(), String(query.window.fromMicroseconds),
            String(query.window.toMicroseconds!), String(query.knownMicroseconds),
            query.subjectID?.uuidString.lowercased() ?? "-", query.locationID?.uuidString.lowercased() ?? "-"]
        return SHA256.hash(data: Data(("SQUIDRA-CHANGES-CURSOR-1\n" + fields.joined(separator: "\n")).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    private struct Continuation: Codable {
        let schemaVersion: String, queryDigest: String
        let throughSequence: Int64, availableThroughSequence: Int64, afterMicroseconds: Int64
        let afterFactId: UUID
        init(_ cursor: WorldChangesCursor) {
            schemaVersion = "1"; queryDigest = WorldChangesTool.fingerprint(cursor.query)
            throughSequence = cursor.throughSequence; availableThroughSequence = cursor.availableThroughSequence
            afterMicroseconds = cursor.afterValidMicroseconds; afterFactId = cursor.afterFactID
        }
        func encoded() throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let text = try encoder.encode(self).base64EncodedString()
            guard text.utf8.count <= 2048 else { throw ToolError.invalidOutput }; return text
        }
        static func decode(_ text: String, query: WorldChangesQuery) throws -> WorldChangesCursor {
            do {
                guard text.utf8.count <= 2048, let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text else { throw ToolError.invalidInput }
                _ = try JSONDocument(bytes, maximumBytes: 1536)
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      Set(object.keys) == ["schemaVersion","queryDigest","throughSequence","availableThroughSequence","afterMicroseconds","afterFactId"] else { throw ToolError.invalidInput }
                let value = try JSONDecoder().decode(Self.self, from: bytes)
                guard value.schemaVersion == "1", value.queryDigest == WorldChangesTool.fingerprint(query) else { throw ToolError.invalidInput }
                return try WorldChangesCursor(query: query, throughSequence: value.throughSequence,
                    availableThroughSequence: value.availableThroughSequence, afterValidMicroseconds: value.afterMicroseconds, afterFactID: value.afterFactId)
            } catch { throw ToolError.invalidInput }
        }
    }
    public func execute(_ call: ToolCall) async throws -> Data {
        try Task.checkCancellation()
        guard call.tool == (try Self.definition()).id else { throw ToolError.invalidInput }
        let request = try Request.decode(call.input), query = try request.query(actor: call.actorID)
        guard call.target == request.target else { throw ToolError.policyDenied }
        guard ContinuousClock.now < call.deadline else { throw ToolError.timedOut }
        let cursor = try request.cursor.map { try Continuation.decode($0, query: query) }
        let page = try await world.changes(query, cursor: cursor, limit: request.limit, deadline: call.deadline)
        try Task.checkCancellation()
        guard ContinuousClock.now < call.deadline else { throw ToolError.timedOut }
        guard page.changes.count <= request.limit, page.throughSequence >= 0,
              page.availableThroughSequence >= page.throughSequence,
              cursor.map({ $0.throughSequence == page.throughSequence && $0.availableThroughSequence == page.availableThroughSequence }) ?? true else { throw ToolError.invalidOutput }
        var facts: [UUID: WorldLocationFact] = [:], changes: [[String: Any]] = []
        var lastPosition = cursor.map { ($0.afterValidMicroseconds, $0.afterFactID.uuidString) }
        for change in page.changes {
            let current = change.current, position = (change.current.valid.fromMicroseconds,change.id.uuidString)
            guard change.id == current.id, current.actorID == call.actorID,
                  query.subjectID.map({ current.subjectID == $0 }) ?? true,
                  current.valid.fromMicroseconds >= query.window.fromMicroseconds, current.valid.fromMicroseconds < query.window.toMicroseconds!,
                  WorldFactWire.contains(current.transaction,query.knownMicroseconds),
                  lastPosition.map({ position > $0 }) ?? true,
                  change.previous.count <= 32, Set(change.previous.map(\.id)).count == change.previous.count,
                  !change.previous.contains(where: { $0.id == current.id }),
                  query.locationID.map({ location in current.locationID == location || change.previous.contains(where: { $0.locationID == location }) }) ?? true else { throw ToolError.invalidOutput }
            guard change.previous.allSatisfy({ prior in
                if change.kind == .correction {
                    return prior.transaction.toMicroseconds == current.transaction.fromMicroseconds
                }
                return prior.valid.toMicroseconds == current.valid.fromMicroseconds
                    && WorldFactWire.contains(prior.transaction,query.knownMicroseconds)
            }) else { throw ToolError.invalidOutput }
            let reconstructed = try WorldChange(current: current, previous: change.previous, isCorrection: change.kind == .correction,
                conflictingCurrent: change.uncertainty.contains(.conflictingLocations), projectionBehind: page.projectionBehind)
            guard reconstructed.kind == change.kind, reconstructed.supportingEventIDs == change.supportingEventIDs,
                  reconstructed.uncertainty == change.uncertainty else { throw ToolError.invalidOutput }
            for fact in [current] + change.previous {
                _ = try WorldFactWire.encode(fact, actor: call.actorID, subject: current.subjectID)
                if let old = facts[fact.id], old != fact { throw ToolError.invalidOutput }
                facts[fact.id] = fact
                guard facts.count <= 32 else { throw ToolError.invalidOutput }
            }
            lastPosition = position
            changes.append(["id": change.id.uuidString.lowercased(), "subjectId": current.subjectID.uuidString.lowercased(),
                "kind": change.kind.rawValue, "effectiveAt": try RFC3339.format(change.effectiveAt),
                "currentFactId": current.id.uuidString.lowercased(), "previousFactIds": change.previous.map { $0.id.uuidString.lowercased() }.sorted(),
                "supportingEventIds": change.supportingEventIDs.map { $0.uuidString.lowercased() }, "uncertainty": change.uncertainty.map(\.rawValue).sorted()])
        }
        if let next = page.next {
            guard let lastPosition, !page.changes.isEmpty, next.query == query,
                  next.throughSequence == page.throughSequence, next.availableThroughSequence == page.availableThroughSequence,
                  next.afterValidMicroseconds == lastPosition.0, next.afterFactID.uuidString == lastPosition.1 else { throw ToolError.invalidOutput }
        }
        let output: [String: Any] = ["schemaVersion": "1", "actorId": call.actorID.uuidString.lowercased(),
            "from": try RFC3339.format(query.window.from), "to": try RFC3339.format(query.window.to!), "knownAt": try RFC3339.format(query.knownAt),
            "subjectId": query.subjectID?.uuidString.lowercased() as Any? ?? NSNull(), "locationId": query.locationID?.uuidString.lowercased() as Any? ?? NSNull(),
            "changes": changes, "facts": try facts.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { try WorldFactWire.encode($0, actor: call.actorID) },
            "projectedThroughSequence": String(page.throughSequence), "availableThroughSequence": String(page.availableThroughSequence),
            "projectionBehind": page.projectionBehind, "next": try page.next.map { try Continuation($0).encoded() } as Any? ?? NSNull()]
        let bytes = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys,.withoutEscapingSlashes])
        guard bytes.count <= 131_072 else { throw ToolError.invalidOutput }; return bytes
    }
}
