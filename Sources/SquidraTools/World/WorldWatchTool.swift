import Crypto
import Foundation
import SquidraDomain
import SquidraMemory

/// Host-bound intention port. Models receive only a strict gateway tool.
public struct WorldWatchTool: ToolExecutor {
    private let actorID: UUID
    private let intentions: any IntentionStore
    public init(actorID: UUID, intentions: any IntentionStore) {
        self.actorID = actorID; self.intentions = intentions
    }
    public static func definition() throws -> ToolDefinition {
        try ToolDefinition(id: ToolID(namespace: "world",name: "watch_entity",version: "1.0.0"),
            capability: "world.watch.create",risk: .r1,idempotency: .durableLedger,
            timeoutMilliseconds: 5_000,maximumInputBytes: 1024,maximumOutputBytes: 2048,
            inputSchema: WorldWatchSchemas.inputSchema,outputSchema: WorldWatchSchemas.outputSchema)
    }
    public func registration() throws -> GatewayToolRegistration {
        try GatewayToolRegistration(definition: Self.definition(),surface: .bounded,executor: self,
            resolveTarget: { "entity:" + (try Request.decode($0)).entityId.uuidString.lowercased() })
    }
    private struct Request: Decodable {
        let schemaVersion: String, entityId: UUID, filter: String
        static func decode(_ data: Data) throws -> Self {
            do {
                _ = try JSONDocument(data,maximumBytes: 1024)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String:Any],
                      Set(object.keys) == ["schemaVersion","entityId","filter"] else { throw ToolError.invalidInput }
                let value = try JSONDecoder().decode(Self.self,from: data)
                guard value.schemaVersion == "1",value.filter == "confirmed_movement" else { throw ToolError.invalidInput }
                return value
            } catch { throw ToolError.invalidInput }
        }
    }
    public func execute(_ call: ToolCall) async throws -> Data {
        try Task.checkCancellation()
        guard call.actorID == actorID,call.scope.contains("world:watch") else { throw ToolError.policyDenied }
        guard call.tool == (try Self.definition()).id else { throw ToolError.invalidInput }
        let request = try Request.decode(call.input)
        guard call.target == "entity:" + request.entityId.uuidString.lowercased() else { throw ToolError.policyDenied }
        guard ContinuousClock.now < call.deadline else { throw ToolError.timedOut }
        // The gateway key, not model arguments, controls deduplication. Hashing
        // preserves the full 256-byte ledger key within the store's 128-byte cap.
        let key = "world.watch_entity@1:" + SHA256.hash(data: Data(call.idempotencyKey.utf8)).map { String(format: "%02x",$0) }.joined()
        let watch = try await intentions.watch(entityID: request.entityId,key: key,
            deadline: min(call.deadline,.now.advanced(by: .seconds(4))))
        guard watch.actorID == actorID,watch.entityID == request.entityId,watch.afterSequence >= 0 else { throw ToolError.invalidOutput }
        let result: [String:Any] = ["schemaVersion":"1","actorId":actorID.uuidString.lowercased(),
            "entityId":watch.entityID.uuidString.lowercased(),"intentionId":watch.id.uuidString.lowercased(),
            "status":watch.status.rawValue,"filter":"confirmed_movement","channel":"internal",
            "afterSequence":String(watch.afterSequence)]
        return try JSONSerialization.data(withJSONObject: result,options: [.sortedKeys,.withoutEscapingSlashes])
    }
}
