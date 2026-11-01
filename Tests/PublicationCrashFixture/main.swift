import Foundation
import PostgresNIO
import SquidraAgentRuntime
import SquidraCognition
import SquidraDomain
import SquidraPostgres
import SquidraProtocols
import SquidraSecurity
import SquidraTemporal
import SquidraTools

struct Manifest: Codable { let actor: UUID,run: UUID,version: Int64 }
enum Failure: Error { case invalid }
actor AuthoredModel: LanguageModel {
    nonisolated let descriptor = ModelDescriptor(id:"authored-crash",modelVersion:"1",location:.local,capabilities:[.text,.structuredOutput])
    let entity: UUID,at: String
    private(set) var calls = 0
    init(entity: UUID,at: String) { self.entity = entity;self.at = at }
    func generate(_ request: ModelRequest) throws -> ModelResponse {
        calls += 1
        let object: [String:Any]
        if calls == 1 {
            object = ["schemaVersion":"1","tool":"world.get_entity_location@1.0.0","arguments":["schemaVersion":"1","entityId":entity.uuidString,"validAt":at,"knownAt":at]]
        } else if calls == 2 {
            object = ["schemaVersion":"1","claims":[["kind":"unknown","subjectId":entity.uuidString,"citations":[]]]]
        } else { throw Failure.invalid }
        return ModelResponse(requestID:request.id,modelID:descriptor.id,modelVersion:descriptor.modelVersion,
            text:String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self),outputTokens:64,costMicroUSD:0)
    }
}
@main struct PublicationCrashFixture {
    static func main() async {
        do { try await run() } catch { print("PUBLICATION_FIXTURE_FAILED");exit(1) }
    }
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment,args = CommandLine.arguments
        guard args.count == 3,["seed","verify"].contains(args[1]),env["SQUIDRA_PUBLICATION_CRASH_FIXTURE"] == "1",
              let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw Failure.invalid }
        let marker = URL(fileURLWithPath:args[2])
        let client = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            if args[1] == "seed" {
                let actor = UUID(),entity = UUID(),clock = try SystemClock(timeZone:IANATimeZone(identifier:"Etc/UTC")),at = try clock.now()
                _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect()
                let request = try ReadRunRequest(actorID:actor,question:"Where is the authored fixture?",planningScope:ReadPlanningScope(entities:[PlanningEntity(id:entity,label:"Fixture")]),
                    effectiveToolScope:["world:read"],intent:.historical,modelOptions:ReadPlanningOptions(deadline:UTCInstant(secondsSince1970:at.secondsSince1970+15)))
                let binding = AGUIRunBinding(actorID:actor,runID:request.runID,threadID:UUID(),requestID:request.requestID)
                let events = PostgresRunEventStore(client:client,actorID:actor),publication = PostgresRunPublicationStore(client:client,actorID:actor)
                _ = try await events.create(binding,retentionSeconds:3600,deadline:.now.advanced(by:.seconds(4)))
                try await PostgresReadRunTaskStore(client:client,actorID:actor).save(StoredReadRunTask(request:request,threadID:binding.threadID),deadline:.now.advanced(by:.seconds(4)))
                _ = try await publication.claim(binding,maximumExecutionSeconds:15,at:at,deadline:.now.advanced(by:.seconds(4)))
                let model = try AuthoredModel(entity:entity,at:RFC3339.format(at))
                let tool = try WorldLocationTool(world:PostgresLocationProjection(actorID:actor,client:client)).registration()
                let permission = HostActionPermission(actorID:actor,tool:tool.definition.id,capability:tool.definition.capability,
                    targets:["entity:"+entity.uuidString.lowercased()],scope:["world:read"],expiresAt:.now.advanced(by:.seconds(30)))
                let engine = try ReadRunEngine(router:ModelRouter(models:[model],clock:clock),gateway:ActionGateway(tools:[tool],policy:HostActionPolicy(permissions:[permission])),
                    store:PostgresRunStore(client:client),clock:clock,freshness:AnswerFreshnessPolicy(maximumObservationAgeSeconds:60,minimumCurrentConfidence:Confidence(0.5)),
                    completions:PostgresReadRunCompletionStore(client:client,actorID:actor))
                let result = try await engine.execute(request)
                guard result.snapshot.state == .completed,result.snapshot.calls == 1,await model.calls == 2 else { throw Failure.invalid }
                let status = try await publication.status(actorID:actor,runID:request.runID,deadline:.now.advanced(by:.seconds(4)))
                guard status.phase == .running,status.stream.nextSequence == 2 else { throw Failure.invalid }
                try JSONEncoder().encode(Manifest(actor:actor,run:request.runID,version:result.snapshot.version)).write(to:marker,options:.atomic)
                try await Task.sleep(for:.seconds(120));throw Failure.invalid
            } else {
                let m = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:marker))
                let state = try await PostgresRunStore(client:client).load(actorID:m.actor,runID:m.run,deadline:.now.advanced(by:.seconds(4)))
                guard state.state == .completed,state.version == m.version,state.calls == 1,state.steps == 1 else { throw Failure.invalid }
                let publication = PostgresRunPublicationStore(client:client,actorID:m.actor)
                let status = try await publication.status(actorID:m.actor,runID:m.run,deadline:.now.advanced(by:.seconds(4)))
                guard status.phase == .succeeded,status.stream.nextSequence == 7 else { throw Failure.invalid }
                let page = try await PostgresRunEventStore(client:client,actorID:m.actor).page(actorID:m.actor,runID:m.run,cursor:nil,limit:32,deadline:.now.advanced(by:.seconds(4)))
                guard let archived = try await PostgresReadRunCompletionStore(client:client,actorID:m.actor).load(runID:m.run,deadline:.now.advanced(by:.seconds(4))) else { throw Failure.invalid }
                // The public protocol status already validates the exact six-event shape.
                let jsonRows = try await client.query("SELECT (payload->'value')::text FROM run_events WHERE actor_id=\(m.actor) AND run_id=\(m.run) AND sequence=2").collect()
                guard jsonRows.count == 1 else { throw Failure.invalid }
                let text = try jsonRows[0].decode(String.self)
                guard try JSONSerialization.jsonObject(with:Data(text.utf8)) as? NSDictionary == JSONSerialization.jsonObject(with:archived.answerJSON) as? NSDictionary else { throw Failure.invalid }
                _ = page
                print("PUBLICATION_RECOVERY_VERIFIED")
            }
        }
    }
}
