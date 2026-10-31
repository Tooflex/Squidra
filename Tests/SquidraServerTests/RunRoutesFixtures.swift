import Foundation
import Hummingbird
import HummingbirdTesting
import PostgresNIO
import SquidraAgentRuntime
import SquidraCognition
import SquidraDomain
import SquidraPostgres
import SquidraProtocols
import SquidraSecurity
import SquidraTemporal
import SquidraTools
import SquidraWorld
import XCTest
@testable import SquidraServer

actor HTTPReadModelFixture: LanguageModel {
    nonisolated let descriptor = ModelDescriptor(id:"fixture.http-read",modelVersion:"1",location:.local,capabilities:[.text,.structuredOutput])
    let responses:[String]
    private(set) var calls = 0
    init(plan:String,answer:String) { responses = [plan,answer] }
    func generate(_ request:ModelRequest) throws -> ModelResponse {
        guard calls < responses.count else { throw ModelProviderError.unavailable }
        let value = responses[calls];calls += 1
        return ModelResponse(requestID:request.id,modelID:descriptor.id,modelVersion:descriptor.modelVersion,text:value,outputTokens:128,costMicroUSD:0)
    }
}
actor HTTPWorldReadCounter: WorldStateQuery {
    let projection:PostgresLocationProjection
    private(set) var calls = 0
    init(_ projection:PostgresLocationProjection) { self.projection = projection }
    func state(actorID:UUID,subjectID:UUID,validAt:UTCInstant,knownAt:UTCInstant,deadline:ContinuousClock.Instant) async throws -> WorldStateSnapshot {
        calls += 1
        return try await projection.state(actorID:actorID,subjectID:subjectID,validAt:validAt,knownAt:knownAt,deadline:deadline)
    }
}
actor HTTPGatedAnswerFixture: ReadRunAnswerExecuting {
    private(set) var calls = 0,cancellations = 0
    private var released = false
    func release() { released = true }
    func executeAnswer(_ request:ReadRunRequest) async throws -> GroundedAnswer {
        calls += 1
        do { while !released { try await Task.sleep(for:.milliseconds(2)) };try Task.checkCancellation() }
        catch { if Task.isCancelled { cancellations += 1 };throw error }
        let subject = try XCTUnwrap(request.planningScope.entities.first?.id),at = try RunHTTPTestSupport.clock.now()
        let snapshot = WorldStateSnapshot(actorID:request.actorID,subjectID:subject,validAt:at,knownAt:at,facts:[],projectedThroughSequence:0,availableThroughSequence:0)
        let context = try AnswerEvidenceContext(snapshot:snapshot,expectedActor:request.actorID,intent:request.intent,clock:RunHTTPTestSupport.clock,
            policy:AnswerFreshnessPolicy(maximumObservationAgeSeconds:60,minimumCurrentConfidence:Confidence(0.5)))
        let value = try JSONSerialization.data(withJSONObject:["schemaVersion":"1","claims":[["kind":"unknown","subjectId":subject.uuidString,"citations":[]]]])
        return try GroundedAnswerValidator().validate(ModelResponse(requestID:request.requestID,modelID:"fixture.http-lifecycle",modelVersion:"1",text:String(decoding:value,as:UTF8.self),outputTokens:1,costMicroUSD:0),expectedRequestID:request.requestID,context:context)
    }
}
actor HTTPReplayCounter: RunEventStore {
    let base:PostgresRunEventStore
    private(set) var pages = 0
    init(_ base:PostgresRunEventStore) { self.base = base }
    func create(_ binding:AGUIRunBinding,retentionSeconds:Int,deadline:ContinuousClock.Instant) async throws -> AGUIRunStreamInfo { try await base.create(binding,retentionSeconds:retentionSeconds,deadline:deadline) }
    func append(_ binding:AGUIRunBinding,expectedNextSequence:Int64,events:[AGUIEvent],deadline:ContinuousClock.Instant) async throws -> AGUIRunStreamInfo { try await base.append(binding,expectedNextSequence:expectedNextSequence,events:events,deadline:deadline) }
    func page(actorID:UUID,runID:UUID,cursor:String?,limit:Int,deadline:ContinuousClock.Instant) async throws -> AGUIRunEventPage {
        pages += 1
        return try await base.page(actorID:actorID,runID:runID,cursor:cursor,limit:limit,deadline:deadline)
    }
}
struct RunHTTPHarness: Sendable {
    let actor:UUID,entity:UUID,configuration:ServerConfiguration,client:PostgresClient,token:String
    let events:PostgresRunEventStore,publication:PostgresRunPublicationStore,coordinator:PublishedReadRunCoordinator
    let replay:HTTPReplayCounter
    func app(ownClient:Bool = false,wait:Duration = .zero,submit:Bool = true) throws -> some ApplicationProtocol {
        let submission = try submit ? RunRoutes.Submission(coordinator:coordinator,clock:RunHTTPTestSupport.clock,
            entities:[PlanningEntity(id:entity,label:"Fixture entity")],budget:RunBudget(steps:1,calls:1,repetitions:1,activeMilliseconds:5000)) : nil
        let dependencies = try RunRoutes.Dependencies(actorID:actor,events:replay,publication:publication,runtime:PostgresRunStore(client:client),submission:submission,maximumWait:wait)
        return ServerComposition.application(configuration:configuration,readiness:{ .ready },client:ownClient ? client : nil,runs:dependencies)
    }
}
enum RunHTTPTestSupport {
    static var clock:SystemClock { get throws { try SystemClock(timeZone:IANATimeZone(identifier:"Etc/UTC")) } }
    static func client() throws -> PostgresClient {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw RunEventStoreError.unavailable }
        return try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
    }
    static func configuration(actor:UUID,token:String) throws -> ServerConfiguration {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["SQUIDRA_TEST_DB_PORT"],let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw RunEventStoreError.unavailable }
        return try ServerConfiguration(environment:["SQUIDRA_PORT":"0","SQUIDRA_ACTOR_ID":actor.uuidString,"SQUIDRA_AUTH_TOKEN":token,
            "SQUIDRA_UI_ORIGIN":"http://localhost:3000","SQUIDRA_DB_PORT":port,"SQUIDRA_DB_USER":"squidra","SQUIDRA_DB_PASSWORD":password,"SQUIDRA_DB_NAME":"squidra"])
    }
    static func harness(client:PostgresClient,actor:UUID = UUID(),entity:UUID = UUID(),executor:any ReadRunAnswerExecuting) throws -> RunHTTPHarness {
        let token = (0..<32).map { _ in String(format:"%02x",UInt8.random(in:.min ... .max)) }.joined()
        let events = PostgresRunEventStore(client:client,actorID:actor),publication = PostgresRunPublicationStore(client:client,actorID:actor)
        let coordinator = try PublishedReadRunCoordinator(actorID:actor,executor:executor,events:events,publication:publication,clock:clock,maximumConcurrentRuns:1)
        return try RunHTTPHarness(actor:actor,entity:entity,configuration:configuration(actor:actor,token:token),client:client,token:token,
            events:events,publication:publication,coordinator:coordinator,replay:HTTPReplayCounter(events))
    }
    static func realHarness(client:PostgresClient) async throws -> (RunHTTPHarness,HTTPReadModelFixture,HTTPWorldReadCounter,UUID) {
        let actor = UUID(),subject = UUID(),place = UUID(),frame = UUID(),t0:Int64 = 1_700_000_000_000_000
        for entity in [subject,place] { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect() }
        _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(frame),\(actor),'http-fixture',3,'metres')").collect()
        let change = try LocationFactChange(subjectID:subject,locationID:place,frameID:frame,valid:FactInterval(fromMicroseconds:t0,toMicroseconds:nil),basis:.observed)
        let draft = try WorldEventDraft(actorID:actor,streamID:UUID(),entityIDs:[subject,place],type:change.eventType,
            times:JournalTimes(occurredAt:nil,observedAt:UTCInstant(secondsSince1970:Double(t0)/1_000_000),timeZone:IANATimeZone(identifier:"Europe/Paris")),
            sourceID:"fixture:http-read-private-canary",confidence:Confidence(0.8125),payloadVersion:1,payload:change.encodedPayload(),correlationID:UUID())
        let event = try await PostgresWorldRepository(client:client).append(draft,expectedVersion:0,idempotencyKey:"http-seed",deadline:.now.advanced(by:.seconds(4))).event
        let projection = PostgresLocationProjection(actorID:actor,client:client);try await projection.apply(event)
        let arguments:[String:Any] = ["schemaVersion":"1","entityId":subject.uuidString,"validAt":try RFC3339.format(UTCInstant(secondsSince1970:Double(t0+1_000_000)/1_000_000)),
            "knownAt":try RFC3339.format(UTCInstant(secondsSince1970:Double(event.recordedMicroseconds)/1_000_000))]
        let plan = String(decoding:try JSONSerialization.data(withJSONObject:["schemaVersion":"1","tool":"world.get_entity_location@1.0.0","arguments":arguments]),as:UTF8.self)
        let answer = String(decoding:try JSONSerialization.data(withJSONObject:["schemaVersion":"1","claims":[["kind":"location","subjectId":subject.uuidString,
            "locationId":place.uuidString,"frameId":frame.uuidString,"citations":[draft.id.uuidString]]]]),as:UTF8.self)
        let model = HTTPReadModelFixture(plan:plan,answer:answer),counter = HTTPWorldReadCounter(projection)
        let registration = try WorldLocationTool(world:counter).registration()
        let permission = HostActionPermission(actorID:actor,tool:registration.definition.id,capability:registration.definition.capability,
            targets:["entity:"+subject.uuidString.lowercased()],scope:["world:read"],expiresAt:.now.advanced(by:.seconds(120)))
        let engine = try ReadRunEngine(router:ModelRouter(models:[model],clock:clock),gateway:ActionGateway(tools:[registration],policy:HostActionPolicy(permissions:[permission])),
            store:PostgresRunStore(client:client),clock:clock,freshness:AnswerFreshnessPolicy(maximumObservationAgeSeconds:3600,minimumCurrentConfidence:Confidence(0.5)))
        return (try harness(client:client,actor:actor,entity:subject,executor:engine),model,counter,draft.id)
    }
    static func body(_ entity:UUID) throws -> ByteBuffer {
        .init(bytes:try JSONSerialization.data(withJSONObject:["schemaVersion":"1","entityId":entity.uuidString,"intent":"historical","question":"Read the fixture entity's historical evidence"]))
    }
    static func object(_ body:ByteBuffer) throws -> [String:Any] { try XCTUnwrap(JSONSerialization.jsonObject(with:Data(body.readableBytesView)) as? [String:Any]) }
    static func frames(_ body:ByteBuffer) throws -> [(String,[String:Any])] {
        try String(buffer:body).components(separatedBy:"\n\n").compactMap { block in
            let lines = block.components(separatedBy:"\n")
            guard let id = lines.first(where:{ $0.hasPrefix("id: ") }),let data = lines.first(where:{ $0.hasPrefix("data: ") }) else { return nil }
            return (String(id.dropFirst(4)),try XCTUnwrap(JSONSerialization.jsonObject(with:Data(data.dropFirst(6).utf8)) as? [String:Any]))
        }
    }
    static func wait(_ predicate:@Sendable () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by:.seconds(10))
        while !(await predicate()) { guard ContinuousClock.now < end else { throw RunEventStoreError.timedOut };try await Task.sleep(for:.milliseconds(2)) }
    }
    static func completed(_ client:any TestClientProtocol,token:String,path:String) async throws -> [String:Any] {
        let end = ContinuousClock.now.advanced(by:.seconds(10))
        while ContinuousClock.now < end {
            let response = try await client.executeRequest(uri:path,method:.get,headers:[.authorization:"Bearer "+token],body:nil)
            XCTAssertEqual(response.status,.ok)
            let result = try object(response.body)
            if result["outputReady"] as? Bool == true { return result }
            if result["terminal"] as? Bool == true { XCTFail("Worker terminalized without an answer");throw RunEventStoreError.conflict }
            try await Task.sleep(for:.milliseconds(10))
        }
        throw RunEventStoreError.timedOut
    }
    static func withClients(_ body:@Sendable (PostgresClient,PostgresClient) async throws -> Void) async throws {
        let client = try client(),other = try Self.client()
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };group.addTask { await other.run() };defer { group.cancelAll() }
            try await body(client,other)
        }
    }
}
