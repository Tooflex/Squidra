import Foundation
import PostgresNIO
import SquidraMemory
import SquidraPostgres
import SquidraSecurity
import SquidraTools
import XCTest

extension WorldToolsSQLTests {
    func testWatchGatewayRequiresCapabilityAndLedgerAndReplaysDurably() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { XCTFail("Use T13");return }
        let client = try LocalDatabaseConfiguration(port: port,username: "squidra",password: password,database: "squidra").makeClient()
        let actor = UUID(),entity = UUID(),other = UUID(),run = UUID(),foreignRun = UUID(),definition = try WorldWatchTool.definition()
        let target = "entity:"+entity.uuidString.lowercased(),key = String(repeating: "k",count: 256)
        let store = PostgresIntentionStore(actorID: actor,client: client)
        let registration = try WorldWatchTool(actorID: actor,intentions: store).registration()
        let permission = HostActionPermission(actorID: actor,tool: definition.id,capability: definition.capability,
            targets: [target,"entity:"+other.uuidString.lowercased()],scope: ["world:watch"],expiresAt: .now.advanced(by: .seconds(90)))
        let policy = HostActionPolicy(permissions: [permission])
        @Sendable func action(owner: UUID = actor,subject: UUID = entity,scope: Set<String> = ["world:watch"],extra: Bool = false) throws -> GatewayAction {
            var input: [String:Any] = ["schemaVersion":"1","entityId":subject.uuidString,"filter":"confirmed_movement"]
            if extra { input["actorId"] = owner.uuidString }
            return try GatewayAction(actorID: owner,runID: owner == actor ? run : foreignRun,tool: definition.id,target: "entity:"+subject.uuidString.lowercased(),
                arguments: JSONSerialization.data(withJSONObject: input),scope: scope,idempotencyKey: key,deadline: .now.advanced(by: .seconds(5)))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            for id in [entity,other] { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(id),\(actor),'fixture')").collect() }
            _ = try await client.query("INSERT INTO agent_runs(id,actor_id,trace_id) VALUES(\(run),\(actor),\(UUID()))").collect()
            let ledger = ActionLedger(store: PostgresActionLedger(client: client))
            let gateway = try ActionGateway(tools: [registration],policy: policy,ledger: ledger)
            for denied in [try ActionGateway(tools: [registration],ledger: ledger),try ActionGateway(tools: [registration],policy: policy)] {
                do { _ = try await denied.invoke(action());XCTFail("Missing authority/ledger accepted") }
                catch { XCTAssertEqual(error as? ActionGatewayError,.denied) }
            }
            for deniedAction in [try action(owner: UUID()),try action(scope: ["world:read"])] {
                do { _ = try await gateway.invoke(deniedAction);XCTFail("Foreign actor or scope accepted") }
                catch { XCTAssertEqual(error as? ActionGatewayError,.denied) }
            }
            do { _ = try await gateway.invoke(action(extra: true));XCTFail("Injected actor accepted") }
            catch { XCTAssertEqual(error as? ToolError,.invalidInput) }
            guard case .completed(let result) = try await gateway.invoke(action()) else { XCTFail("No watch result");return }
            let output = try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String:Any])
            XCTAssertEqual(output["status"] as? String,"active")
            XCTAssertEqual(output["filter"] as? String,"confirmed_movement")
            XCTAssertEqual(output["channel"] as? String,"internal")
            let id = try XCTUnwrap((output["intentionId"] as? String).flatMap(UUID.init(uuidString:)))
            // New gateway and store instances prove persisted ledger replay.
            let fresh = try ActionGateway(tools: [WorldWatchTool(actorID: actor,intentions: PostgresIntentionStore(actorID: actor,client: client)).registration()],
                policy: policy,ledger: ActionLedger(store: PostgresActionLedger(client: client)))
            guard case .replay(let replay) = try await fresh.invoke(action()) else { XCTFail("No durable replay");return }
            XCTAssertEqual(replay.result?.payload,result.payload)
            do { _ = try await fresh.invoke(action(subject: other));XCTFail("Key changed entity") }
            catch { XCTAssertEqual(error as? ActionLedgerError,.conflict) }
            let rows = try await client.query("SELECT count(*) FROM watch_intentions WHERE actor_id=\(actor)").collect()
            XCTAssertEqual(try rows[0].decode(Int.self),1)
            let records = try await client.query("SELECT count(*) FROM action_ledger WHERE actor_id=\(actor) AND status='succeeded'").collect()
            XCTAssertEqual(try records[0].decode(Int.self),1)
            // The reversible host operation preserves the same intention identity.
            let cancelled = try await store.cancel(id: id,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertEqual(cancelled.status,.cancelled)
            guard case .replay(let historical) = try await fresh.invoke(action()) else { XCTFail("Cancelled watch was recreated");return }
            XCTAssertEqual(historical.result?.payload,result.payload,"Ledger replay describes original result, not current watch state")
            let state = try await store.load(id: id,deadline: .now.advanced(by: .seconds(4)))
            XCTAssertEqual(state?.status,.cancelled)
            // Even an incorrectly permissive policy cannot cross the adapter's host actor.
            let foreign = UUID()
            _ = try await client.query("INSERT INTO agent_runs(id,actor_id,trace_id) VALUES(\(foreignRun),\(foreign),\(UUID()))").collect()
            let broad = HostActionPermission(actorID: foreign,tool: definition.id,capability: definition.capability,targets: [target],scope: ["world:watch"],expiresAt: .now.advanced(by: .seconds(30)))
            let wrongActor = try ActionGateway(tools: [registration],policy: HostActionPolicy(permissions: [broad]),ledger: ledger)
            do { _ = try await wrongActor.invoke(action(owner: foreign));XCTFail("Adapter crossed actor boundary") }
            catch { XCTAssertEqual(error as? ToolError,.providerFailure) }
        }
    }
}

final class WorldWatchSchemaTests: XCTestCase {
    func testStrictSchemasMatchDeploymentAndRejectInventedEffects() throws {
        let definition = try WorldWatchTool.definition(),catalog = try ToolCatalog(definitions: [definition])
        XCTAssertEqual(definition.risk,.r1);XCTAssertEqual(definition.idempotency,.durableLedger)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (kind,data) in [("input",WorldWatchSchemas.inputSchema),("output",WorldWatchSchemas.outputSchema)] {
            let file = try Data(contentsOf: root.appendingPathComponent("Schemas/tools/world/world.watch_entity.1.0.0.\(kind).json"))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: file) as? NSDictionary,try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        }
        for filter in ["jitter","any_change","email"] {
            let input = try JSONSerialization.data(withJSONObject: ["schemaVersion":"1","entityId":UUID().uuidString,"filter":filter])
            XCTAssertThrowsError(try catalog.validateInput(input,for: definition.id))
        }
    }
}
