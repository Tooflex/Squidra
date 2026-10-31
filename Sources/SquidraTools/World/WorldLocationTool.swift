import Foundation
import SquidraDomain
import SquidraWorld

/// Read-only injection grants no journal append, SQL, or intention-store access.
public struct WorldLocationTool: ToolExecutor {
    private let world: any WorldStateQuery
    public init(world: any WorldStateQuery) { self.world = world }

    public static func definition() throws -> ToolDefinition {
        try ToolDefinition(id: ToolID(namespace: "world", name: "get_entity_location", version: "1.0.0"),
            capability: "world.location.read", risk: .r0, idempotency: .readOnly,
            timeoutMilliseconds: 5_000, maximumInputBytes: 1024, maximumOutputBytes: 131_072,
            inputSchema: WorldLocationSchemas.inputSchema, outputSchema: WorldLocationSchemas.outputSchema)
    }
    public func registration() throws -> GatewayToolRegistration {
        try GatewayToolRegistration(definition: Self.definition(), surface: .bounded, executor: self,
            resolveTarget: { input in "entity:" + (try Request.decode(input)).entityId.uuidString.lowercased() })
    }
    private struct Request: Decodable {
        let schemaVersion: String, entityId: UUID, validAt: String, knownAt: String
        static func decode(_ bytes: Data) throws -> Self {
            // Catalog validation also runs before target resolution. Keep the
            // adapter defensive when used by another trusted composition root.
            do {
                _ = try JSONDocument(bytes, maximumBytes: 1024)
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      Set(object.keys) == ["schemaVersion", "entityId", "validAt", "knownAt"] else { throw ToolError.invalidInput }
                let request = try JSONDecoder().decode(Self.self, from: bytes)
                guard request.schemaVersion == "1" else { throw ToolError.invalidInput }
                _ = try RFC3339.parse(request.validAt); _ = try RFC3339.parse(request.knownAt)
                return request
            } catch { throw ToolError.invalidInput }
        }
    }
    public func execute(_ call: ToolCall) async throws -> Data {
        try Task.checkCancellation()
        guard call.tool == (try Self.definition()).id else { throw ToolError.invalidInput }
        let request = try Request.decode(call.input)
        guard call.target == "entity:" + request.entityId.uuidString.lowercased() else { throw ToolError.policyDenied }
        guard ContinuousClock.now < call.deadline else { throw ToolError.timedOut }
        let times = try JournalTimes(occurredAt: RFC3339.parse(request.knownAt), observedAt: RFC3339.parse(request.validAt),
            timeZone: IANATimeZone(identifier: "Etc/UTC"))
        let validAt = times.observedAt, knownAt = times.occurredAt!
        let snapshot: WorldStateSnapshot
        var notFound = false
        do {
            snapshot = try await world.state(actorID: call.actorID, subjectID: request.entityId,
                validAt: validAt, knownAt: knownAt, deadline: call.deadline)
        } catch WorldProjectionError.notFound {
            // Foreign and absent entities share one non-disclosing outcome.
            notFound = true
            snapshot = WorldStateSnapshot(actorID: call.actorID, subjectID: request.entityId,
                validAt: validAt, knownAt: knownAt, facts: [], projectedThroughSequence: 0, availableThroughSequence: 0)
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < call.deadline else { throw ToolError.timedOut }
        guard snapshot.actorID == call.actorID, snapshot.subjectID == request.entityId,
              snapshot.validAt == validAt, snapshot.knownAt == knownAt,
              snapshot.projectedThroughSequence >= 0, snapshot.availableThroughSequence >= snapshot.projectedThroughSequence,
              snapshot.facts.count <= 32, Set(snapshot.facts.map(\.id)).count == snapshot.facts.count else { throw ToolError.invalidOutput }
        func contains(_ interval: FactInterval, _ micros: Int64) -> Bool {
            interval.fromMicroseconds <= micros && (interval.toMicroseconds.map { micros < $0 } ?? true)
        }
        func interval(_ value: FactInterval) throws -> [String: Any] {
            ["from": try RFC3339.format(value.from), "to": try value.to.map(RFC3339.format) as Any? ?? NSNull()]
        }
        let facts: [[String: Any]] = try snapshot.facts.sorted { $0.id.uuidString < $1.id.uuidString }.map { fact in
            guard fact.actorID == call.actorID, fact.subjectID == request.entityId, fact.id == fact.sourceEventID,
                  !fact.sourceID.isEmpty, fact.sourceID.utf8.count <= 256,
                  !fact.sourceID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  contains(fact.valid,times.observedMicroseconds), contains(fact.transaction,times.occurredMicroseconds!),
                  fact.transaction.from == fact.timestamps.recordedAt else { throw ToolError.invalidOutput }
            return ["id": fact.id.uuidString.lowercased(), "subjectId": fact.subjectID.uuidString.lowercased(),
                "locationId": fact.locationID.uuidString.lowercased(), "frameId": fact.frameID.uuidString.lowercased(),
                "sourceEventId": fact.sourceEventID.uuidString.lowercased(), "source": fact.sourceID,
                "confidence": fact.confidence.value, "basis": fact.basis.rawValue,
                "occurredAt": try fact.timestamps.occurredAt.map(RFC3339.format) as Any? ?? NSNull(),
                "observedAt": try RFC3339.format(fact.timestamps.observedAt), "recordedAt": try RFC3339.format(fact.timestamps.recordedAt),
                "timeZone": fact.timestamps.timeZone.identifier, "valid": try interval(fact.valid), "transaction": try interval(fact.transaction)]
        }
        // Derive uncertainty from the retained facts rather than trusting a
        // supplied summary that could hide contradictory or inferred evidence.
        let checked = WorldStateSnapshot(actorID: call.actorID, subjectID: request.entityId, validAt: validAt, knownAt: knownAt,
            facts: snapshot.facts, projectedThroughSequence: snapshot.projectedThroughSequence, availableThroughSequence: snapshot.availableThroughSequence)
        let output: [String: Any] = ["schemaVersion": "1", "actorId": call.actorID.uuidString.lowercased(),
            "entityId": request.entityId.uuidString.lowercased(), "validAt": try RFC3339.format(validAt), "knownAt": try RFC3339.format(knownAt),
            "status": notFound ? "not_found" : facts.isEmpty ? "no_evidence" : "evidence", "facts": facts,
            "uncertainty": checked.uncertainty.map(\.rawValue).sorted(),
            "projectedThroughSequence": notFound ? NSNull() : String(snapshot.projectedThroughSequence) as Any,
            "availableThroughSequence": notFound ? NSNull() : String(snapshot.availableThroughSequence) as Any]
        let bytes = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= 131_072 else { throw ToolError.invalidOutput }
        return bytes
    }
}
