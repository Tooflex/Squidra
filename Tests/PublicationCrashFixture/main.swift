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
    nonisolated let descriptor: ModelDescriptor
    let answerOnly: Bool
    let entity: UUID,at: String
    private(set) var calls = 0
    init(entity: UUID,at: String,answerOnly: Bool = false,cost: Int64 = 0) {
        self.entity = entity;self.at = at;self.answerOnly = answerOnly
        descriptor = ModelDescriptor(id:"authored-crash",modelVersion:"1",location:.local,capabilities:[.text,.structuredOutput],maximumCostMicroUSD:cost)
    }
    func generate(_ request: ModelRequest) throws -> ModelResponse {
        calls += 1
        let object: [String:Any]
        if calls == 1 && !answerOnly {
            object = ["schemaVersion":"1","tool":"world.get_entity_location@1.0.0","arguments":["schemaVersion":"1","entityId":entity.uuidString,"validAt":at,"knownAt":at]]
        } else if calls == (answerOnly ? 1 : 2) {
            object = ["schemaVersion":"1","claims":[["kind":"unknown","subjectId":entity.uuidString,"citations":[]]]]
        } else { throw Failure.invalid }
        return ModelResponse(requestID:request.id,modelID:descriptor.id,modelVersion:descriptor.modelVersion,
            text:String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self),outputTokens:64,costMicroUSD:descriptor.maximumCostMicroUSD == 0 ? 0 : 3)
    }
}
/// Test-only boundary: commit the real archive, then await the harness's SIGKILL.
struct SuspendedPlanStore: ReadRunPlanStore {
    let base: PostgresReadRunPlanStore,marker: URL,model: AuthoredModel
    func save(snapshot: RunSnapshot,requestID: UUID,plan: PlannedRead,deadline: ContinuousClock.Instant) async throws {
        try await base.save(snapshot:snapshot,requestID:requestID,plan:plan,deadline:deadline)
        guard snapshot.state == .planning,snapshot.steps == 0,snapshot.calls == 0,
              await model.calls == 1,
              plan.routing.reservedCostUpperBoundMicroUSD == 5 else { throw Failure.invalid }
        try JSONEncoder().encode(Manifest(actor:snapshot.actorID,run:snapshot.id,version:snapshot.version)).write(to:marker,options:.atomic)
        try await Task.sleep(for:.seconds(120));throw Failure.invalid
    }
    func load(runID: UUID,deadline: ContinuousClock.Instant) async throws -> StoredReadRunPlan? {
        try await base.load(runID:runID,deadline:deadline)
    }
}
struct SuspendedToolResultStore: ReadRunToolResultStore {
    let base: PostgresReadRunToolResultStore,marker: URL,model: AuthoredModel
    func save(snapshot: RunSnapshot,requestID: UUID,command: ActionCommand,result: UntrustedToolResult,deadline: ContinuousClock.Instant) async throws {
        try await base.save(snapshot:snapshot,requestID:requestID,command:command,result:result,deadline:deadline)
        guard snapshot.state == .executingTool,snapshot.steps == 1,snapshot.calls == 1,await model.calls == 1 else { throw Failure.invalid }
        try JSONEncoder().encode(Manifest(actor:snapshot.actorID,run:snapshot.id,version:snapshot.version)).write(to:marker,options:.atomic)
        try await Task.sleep(for:.seconds(120));throw Failure.invalid
    }
    func load(runID: UUID,deadline: ContinuousClock.Instant) async throws -> StoredReadRunToolResult? {
        try await base.load(runID:runID,deadline:deadline)
    }
}
struct SuspendedAnswerStore: ReadRunAnswerStore {
    let base: PostgresReadRunAnswerStore,marker: URL,model: AuthoredModel
    func save(snapshot: RunSnapshot,response: RoutedModelResponse,deadline: ContinuousClock.Instant) async throws {
        try await base.save(snapshot:snapshot,response:response,deadline:deadline)
        guard snapshot.state == .responding,await model.calls == 2 else { throw Failure.invalid }
        try JSONEncoder().encode(Manifest(actor:snapshot.actorID,run:snapshot.id,version:snapshot.version)).write(to:marker,options:.atomic)
        try await Task.sleep(for:.seconds(120));throw Failure.invalid
    }
    func load(runID: UUID,deadline: ContinuousClock.Instant) async throws -> StoredReadRunAnswer? { try await base.load(runID:runID,deadline:deadline) }
}
struct SuspendedCompletionStore: ReadRunCompletionStore {
    let base: PostgresReadRunCompletionStore,marker: URL,model: AuthoredModel
    func save(snapshot: RunSnapshot,answer: GroundedAnswer,deadline: ContinuousClock.Instant) async throws {
        try await base.save(snapshot:snapshot,answer:answer,deadline:deadline)
        guard snapshot.state == .responding,await model.calls == 2 else { throw Failure.invalid }
        try JSONEncoder().encode(Manifest(actor:snapshot.actorID,run:snapshot.id,version:snapshot.version)).write(to:marker,options:.atomic)
        try await Task.sleep(for:.seconds(120));throw Failure.invalid
    }
    func load(runID: UUID,deadline: ContinuousClock.Instant) async throws -> StoredReadRunCompletion? { try await base.load(runID:runID,deadline:deadline) }
}
@main struct PublicationCrashFixture {
    static func main() async {
        do { try await run() }
        catch let failure as ReadRunFailure { print("PUBLICATION_FIXTURE_FAILED:"+failure.code.rawValue);exit(1) }
        catch { print("PUBLICATION_FIXTURE_FAILED");exit(1) }
    }
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment,args = CommandLine.arguments
        guard args.count == 3,["seed","seed-early","seed-plan","seed-result","seed-answer","seed-completion","resume-answer","resume-completion","resume-early","resume-plan","resume-result","verify"].contains(args[1]),env["SQUIDRA_PUBLICATION_CRASH_FIXTURE"] == "1",
              let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw Failure.invalid }
        let marker = URL(fileURLWithPath:args[2])
        let client = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            if args[1].hasPrefix("seed") {
                let actor = UUID(),entity = UUID(),clock = try SystemClock(timeZone:IANATimeZone(identifier:"Etc/UTC")),at = try clock.now()
                _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect()
                let request = try ReadRunRequest(actorID:actor,question:"Where is the authored fixture?",planningScope:ReadPlanningScope(entities:[PlanningEntity(id:entity,label:"Fixture")]),
                    effectiveToolScope:["world:read"],intent:.historical,modelOptions:ReadPlanningOptions(maximumCostMicroUSD:["seed-plan","seed-result","seed-answer","seed-completion"].contains(args[1]) ? 10 : 0,deadline:UTCInstant(secondsSince1970:at.secondsSince1970+15)),budget:RunBudget(activeMilliseconds:15000))
                let binding = AGUIRunBinding(actorID:actor,runID:request.runID,threadID:UUID(),requestID:request.requestID)
                let events = PostgresRunEventStore(client:client,actorID:actor),publication = PostgresRunPublicationStore(client:client,actorID:actor)
                _ = try await events.create(binding,retentionSeconds:3600,deadline:.now.advanced(by:.seconds(4)))
                try await PostgresReadRunTaskStore(client:client,actorID:actor).save(StoredReadRunTask(request:request,threadID:binding.threadID),deadline:.now.advanced(by:.seconds(4)))
                _ = try await publication.claim(binding,maximumExecutionSeconds:15,at:at,deadline:.now.advanced(by:.seconds(4)))
                if args[1] == "seed-early" {
                    let controller = try await RunController.create(actorID:actor,id:request.runID,traceID:request.traceID,budget:RunBudget(activeMilliseconds:15000),store:PostgresRunStore(client:client),clock:clock)
                    _ = try await controller.transition(to:.validating)
                    let checkpoint = try await controller.transition(to:.contextLoading)
                    try JSONEncoder().encode(Manifest(actor:actor,run:request.runID,version:checkpoint.version)).write(to:marker,options:.atomic)
                    try await Task.sleep(for:.seconds(120));throw Failure.invalid
                }
                let (engine,model) = try makeEngine(request:request,client:client,clock:clock,planMarker:args[1] == "seed-plan" ? marker : nil,resultMarker:args[1] == "seed-result" ? marker : nil,answerMarker:args[1] == "seed-answer" ? marker : nil,completionMarker:args[1] == "seed-completion" ? marker : nil)
                let result = try await engine.execute(request)
                guard result.snapshot.state == .completed,result.snapshot.calls == 1,await model.calls == 2 else { throw Failure.invalid }
                let status = try await publication.status(actorID:actor,runID:request.runID,deadline:.now.advanced(by:.seconds(4)))
                guard status.phase == .running,status.stream.nextSequence == 2 else { throw Failure.invalid }
                try JSONEncoder().encode(Manifest(actor:actor,run:request.runID,version:result.snapshot.version)).write(to:marker,options:.atomic)
                try await Task.sleep(for:.seconds(120));throw Failure.invalid
            } else {
                let m = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:marker))
                if args[1].hasPrefix("resume-") {
                    let savedAnswer = ["resume-answer","resume-completion"].contains(args[1])
                    let savedResult = args[1] == "resume-result"
                    let savedPlan = args[1] == "resume-plan" || savedResult || savedAnswer
                    guard let task = try await PostgresReadRunTaskStore(client:client,actorID:m.actor).load(runID:m.run,deadline:.now.advanced(by:.seconds(4))) else { throw Failure.invalid }
                    let original = try await PostgresRunStore(client:client).load(actorID:m.actor,runID:m.run,deadline:.now.advanced(by:.seconds(4)))
                    guard original.version == m.version,original.budget.activeMilliseconds > 0,original.budget.activeMilliseconds <= 15000 else { throw Failure.invalid }
                    let clock = try SystemClock(timeZone:IANATimeZone(identifier:"Etc/UTC"))
                    let (engine,model) = try makeEngine(request:task.request,client:client,clock:clock,answerOnly:savedPlan)
                    let priorCompletion = try await PostgresReadRunCompletionStore(client:client,actorID:m.actor).load(runID:m.run,deadline:.now.advanced(by:.seconds(4)))
                    let snapshot: RunSnapshot,reserved: Int64,planningReserved: Int64
                    if savedAnswer {
                        let recovered = try await engine.resumeSavedAnswer(task.request,expectedVersion:m.version)
                        snapshot = recovered.snapshot;reserved = recovered.reservedModelCostUpperBoundMicroUSD;planningReserved = recovered.planningRouting.reservedCostUpperBoundMicroUSD
                    } else {
                        let result: ReadRunResult
                        if savedResult { result = try await engine.resumeSavedToolResult(task.request,expectedVersion:m.version) }
                        else if savedPlan { result = try await engine.resumeSavedPlan(task.request,expectedVersion:m.version) }
                        else { result = try await engine.resumeBeforePlanning(task.request,expectedVersion:m.version) }
                        snapshot = result.snapshot;reserved = result.reservedModelCostUpperBoundMicroUSD;planningReserved = result.planningRouting.reservedCostUpperBoundMicroUSD
                    }
                    guard snapshot.state == .completed,snapshot.calls == 1,snapshot.steps == 1,
                          snapshot.budget == original.budget,snapshot.activeMilliseconds >= original.activeMilliseconds,
                          await model.calls == (savedAnswer ? 0 : (savedPlan ? 1 : 2)) else { throw Failure.invalid }
                    if args[1] == "resume-completion" {
                        guard let priorCompletion,let after = try await PostgresReadRunCompletionStore(client:client,actorID:m.actor).load(runID:m.run,deadline:.now.advanced(by:.seconds(4))),
                              after.answerJSON == priorCompletion.answerJSON,after.respondingVersion == priorCompletion.respondingVersion else { throw Failure.invalid }
                    }
                    try JSONEncoder().encode(Manifest(actor:m.actor,run:m.run,version:snapshot.version)).write(to:marker,options:.atomic)
                    if savedPlan { guard planningReserved == 5,reserved == 10 else { throw Failure.invalid } }
                    print(savedAnswer ? "SAVED_ANSWER_RECOVERY_VERIFIED" : (savedResult ? "SAVED_RESULT_RECOVERY_VERIFIED" : (savedPlan ? "SAVED_PLAN_RECOVERY_VERIFIED" : "PREPLANNING_RECOVERY_VERIFIED")))
                    return
                }
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
    static func makeEngine(request:ReadRunRequest,client:PostgresClient,clock:SystemClock,planMarker: URL? = nil,resultMarker: URL? = nil,answerMarker: URL? = nil,completionMarker: URL? = nil,answerOnly: Bool = false) throws -> (ReadRunEngine,AuthoredModel) {
        let actor = request.actorID,entity = request.planningScope.entities[0].id
        let model = try AuthoredModel(entity:entity,at:RFC3339.format(clock.now()),answerOnly:answerOnly,cost:request.modelOptions.maximumCostMicroUSD == 10 ? 5 : 0)
        let tool = try WorldLocationTool(world:PostgresLocationProjection(actorID:actor,client:client)).registration()
        let permission = HostActionPermission(actorID:actor,tool:tool.definition.id,capability:tool.definition.capability,
            targets:["entity:"+entity.uuidString.lowercased()],scope:["world:read"],expiresAt:.now.advanced(by:.seconds(30)))
        let planStore = PostgresReadRunPlanStore(client:client,actorID:actor)
        let plans: any ReadRunPlanStore
        if let planMarker { plans = SuspendedPlanStore(base:planStore,marker:planMarker,model:model) } else { plans = planStore }
        let resultStore = PostgresReadRunToolResultStore(client:client,actorID:actor)
        let results: any ReadRunToolResultStore
        if let resultMarker { results = SuspendedToolResultStore(base:resultStore,marker:resultMarker,model:model) } else { results = resultStore }
        let answerStore = PostgresReadRunAnswerStore(client:client,actorID:actor)
        let answers: any ReadRunAnswerStore
        if let answerMarker { answers = SuspendedAnswerStore(base:answerStore,marker:answerMarker,model:model) } else { answers = answerStore }
        let completionStore = PostgresReadRunCompletionStore(client:client,actorID:actor)
        let completions: any ReadRunCompletionStore
        if let completionMarker { completions = SuspendedCompletionStore(base:completionStore,marker:completionMarker,model:model) } else { completions = completionStore }
        let engine = try ReadRunEngine(router:ModelRouter(models:[model],clock:clock),gateway:ActionGateway(tools:[tool],policy:HostActionPolicy(permissions:[permission])),
            store:PostgresRunStore(client:client),clock:clock,freshness:AnswerFreshnessPolicy(maximumObservationAgeSeconds:60,minimumCurrentConfidence:Confidence(0.5)),
            completions:completions,plans:plans,toolResults:results,answers:answers)
        return (engine,model)
    }

}
