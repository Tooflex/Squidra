import Foundation
import Hummingbird
import HummingbirdTesting
import PostgresNIO
import SquidraDomain
import SquidraCognition
import SquidraSecurity
import SquidraTools
import SquidraPostgres
import SquidraMeta
import SquidraPerception
import XCTest
@testable import SquidraServer

final class FrameImportRouteTests: XCTestCase, @unchecked Sendable {
    private static var fixture: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/providers/vision-synthetic.v1.json") }
    private static func environment() throws -> [String:String] {
        let env = ProcessInfo.processInfo.environment
        return ["SQUIDRA_PORT":"0","SQUIDRA_AUTH_TOKEN":String(repeating:"a",count:64),"SQUIDRA_ACTOR_ID":UUID().uuidString,"SQUIDRA_UI_ORIGIN":"http://localhost:3000",
                "SQUIDRA_DB_PORT":try XCTUnwrap(env["SQUIDRA_TEST_DB_PORT"]),"SQUIDRA_DB_USER":"squidra","SQUIDRA_DB_PASSWORD":try XCTUnwrap(env["SQUIDRA_TEST_DB_PASSWORD"]),"SQUIDRA_DB_NAME":"squidra",
                "SQUIDRA_SYNTHETIC_IMPORT":"1","SQUIDRA_SYNTHETIC_FIXTURE":fixture.path,"SQUIDRA_SYNTHETIC_CAMERA_ID":UUID().uuidString,"SQUIDRA_SYNTHETIC_SCENE_ID":UUID().uuidString,"SQUIDRA_SYNTHETIC_COORDINATE_FRAME_ID":UUID().uuidString]
    }
    func testExplicitConfigurationAndFrozenFixtureFailClosed() throws {
        let actor = UUID(); XCTAssertNil(try SyntheticImportConfiguration.read(environment:[:],actorID:actor))
        var env = try Self.environment()
        XCTAssertNotNil(try ServerConfiguration(environment:env).syntheticImport)
        for key in env.keys.filter({$0.hasPrefix("SQUIDRA_SYNTHETIC_")}) {
            var missing=env;missing.removeValue(forKey:key);XCTAssertThrowsError(try ServerConfiguration(environment:missing))
        }
        env["SQUIDRA_SYNTHETIC_IMPORT"]="true";XCTAssertThrowsError(try ServerConfiguration(environment:env));env["SQUIDRA_SYNTHETIC_IMPORT"]="1"
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false);defer {try? FileManager.default.removeItem(at:root)}
        let bad=root.appendingPathComponent("fixture.json");try Data("{}".utf8).write(to:bad);env["SQUIDRA_SYNTHETIC_FIXTURE"]=bad.path;XCTAssertThrowsError(try ServerConfiguration(environment:env))
        let link=root.appendingPathComponent("link.json");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:Self.fixture);env["SQUIDRA_SYNTHETIC_FIXTURE"]=link.path;XCTAssertThrowsError(try ServerConfiguration(environment:env))
    }
    func testNormalServerPublishesSourcedSyntheticReceiptAndRejectsUntrustedInputs() async throws {
        let env=try Self.environment(),config=try ServerConfiguration(environment:env),profile=try XCTUnwrap(config.syntheticImport)
        let db=config.database.makeClient(),actor=config.boundary.actorID,scene=profile.policy.locationID,coordinate=profile.policy.coordinateFrameID
        let root=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:Self.fixture)) as? [String:Any])
        let encoded=try XCTUnwrap((root["frames"] as? [[String:Any]])?.first?["imageBase64"] as? String)
        @Sendable func body(_ changes:[String:Any]=[:]) throws -> String {
            var input:[String:Any] = ["schemaVersion":"1","imageBase64":encoded,"permitsLocalProcessing":true];input.merge(changes) {_,new in new}
            return String(decoding:try JSONSerialization.data(withJSONObject:input),as:UTF8.self)
        }
        let headers:HTTPFields=[.authorization:"Bearer "+env["SQUIDRA_AUTH_TOKEN"]!,.contentType:"application/json"]
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask {await db.run()};defer {group.cancelAll()}
            _ = try await db.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(scene),\(actor),'fixture_scene')").collect()
            _ = try await db.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(coordinate),\(actor),'synthetic host scene',3,'metres')").collect()
            try await ServerComposition.live(configuration:config).test(.live) { client in
                try await client.execute(uri:"/api/v1/frames/import",method:.post,body:.init(string:body())) {XCTAssertEqual($0.status,.unauthorized)}
                for (fields,status):([String:Any],HTTPResponse.Status) in [(["permitsLocalProcessing":false],.forbidden),(["actorId":UUID().uuidString],.badRequest),(["frameId":UUID().uuidString],.badRequest),(["permitsLocalProcessing":"true"],.badRequest),(["schemaVersion":"2"],.badRequest),(["imageBase64":"AAAA"],.badRequest),(["imageBase64":Data(repeating:0,count:524289).base64EncodedString()],.badRequest)] {
                    try await client.execute(uri:"/api/v1/frames/import",method:.post,headers:headers,body:.init(string:body(fields))) {XCTAssertEqual($0.status,status)}
                }
                let duplicate="{\"schemaVersion\":\"1\",\"schemaVersion\":\"1\",\"imageBase64\":\"AAAA\",\"permitsLocalProcessing\":true}"
                try await client.execute(uri:"/api/v1/frames/import",method:.post,headers:headers,body:.init(string:duplicate)) {XCTAssertEqual($0.status,.badRequest)}
                var unknown=try XCTUnwrap(Data(base64Encoded:encoded)),chunk=Data([0,0,0,3,116,69,88,116,97,0,98,0,0,0,0])
                var crc:UInt32=0xffffffff
                for byte in chunk[4..<11] {crc ^= UInt32(byte);for _ in 0..<8 {crc=(crc>>1)^((crc&1)==1 ? 0xedb88320 : 0)}};crc ^= 0xffffffff
                chunk.replaceSubrange(11..<15,with:[UInt8(crc>>24),UInt8((crc>>16)&255),UInt8((crc>>8)&255),UInt8(crc&255)]);unknown.insert(contentsOf:chunk,at:unknown.count-12)
                try await client.execute(uri:"/api/v1/frames/import",method:.post,headers:headers,body:.init(string:body(["imageBase64":unknown.base64EncodedString()]))) {XCTAssertEqual($0.status,.serviceUnavailable)}
                let empty=try await db.query("SELECT count(*)::bigint FROM world_events WHERE actor_id=\(actor)").collect();XCTAssertEqual(try empty[0].decode(Int64.self),0)
                try await client.execute(uri:"/api/v1/frames/import",method:.post,headers:headers,body:.init(string:body())) { response in
                    XCTAssertEqual(response.status,.created);XCTAssertEqual(response.headers[.cacheControl],"no-store")
                    let value=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(response.body.readableBytesView)) as? [String:Any])
                    XCTAssertEqual(value["deployment"] as? String,"synthetic");XCTAssertEqual(value["basis"] as? String,"inferred");XCTAssertEqual(value["mediaRetained"] as? Bool,false)
                    XCTAssertEqual((value["cameraId"] as? String)?.lowercased(),profile.policy.cameraID.uuidString.lowercased());XCTAssertEqual(value["modelId"] as? String,"fixture.vision");XCTAssertEqual(value["modelVersion"] as? String,"1.0.0")
                    let entities=try XCTUnwrap(value["entities"] as? [[String:Any]]);XCTAssertFalse(entities.isEmpty)
                    let entity=try XCTUnwrap(entities.first?["id"] as? String),source=try XCTUnwrap(entities.first?["sourceEventId"] as? String)
                    let query:[String:Any] = ["schemaVersion":"1","entityId":entity,"validAt":try XCTUnwrap(value["observedAt"] as? String),"knownAt":try XCTUnwrap(value["knownAt"] as? String)]
                    let queryData=try JSONSerialization.data(withJSONObject:query)
                    try await client.execute(uri:"/api/v1/world/location",method:.post,headers:headers,body:.init(bytes:queryData)) { read in
                        XCTAssertEqual(read.status,.ok)
                        let state=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(read.body.readableBytesView)) as? [String:Any])
                        let facts=try XCTUnwrap(state["facts"] as? [[String:Any]]);XCTAssertEqual(facts.count,1)
                        XCTAssertEqual((facts[0]["sourceEventId"] as? String)?.lowercased(),source.lowercased());XCTAssertEqual(facts[0]["basis"] as? String,"inferred")
                    }
                    let rows=try await db.query("SELECT count(*)::bigint FROM world_events WHERE actor_id=\(actor)").collect();XCTAssertEqual(try rows[0].decode(Int64.self),Int64(entities.count+1))
                }
            }
        }
    }
    func testImportedEntitiesRequireExplicitHostScopeAndSurviveRecomposition() async throws {
        let env = try Self.environment(),config = try ServerConfiguration(environment:env),profile = try XCTUnwrap(config.syntheticImport)
        let db = config.database.makeClient(), actor = config.boundary.actorID,scene = profile.policy.locationID,coordinate = profile.policy.coordinateFrameID
        let model = ImportedQuestionModelFixture()
        let host = try ReadHostConfiguration(models:[model],entities:[],allowImportedEntities:true)
        let noProfile = try ServerConfiguration(environment:env.filter { !$0.key.hasPrefix("SQUIDRA_SYNTHETIC_") })
        XCTAssertThrowsError(try ServerComposition.live(configuration:noProfile,readHost:host))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:Self.fixture)) as? [String:Any])
        let image = try XCTUnwrap((root["frames"] as? [[String:Any]])?.first?["imageBase64"] as? String)
        let body = try JSONSerialization.data(withJSONObject:["schemaVersion":"1","imageBase64":image,"permitsLocalProcessing":true])
        let token = env["SQUIDRA_AUTH_TOKEN"]!, headers:HTTPFields = [.authorization:"Bearer "+token,.contentType:"application/json"]
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await db.run() };defer { group.cancelAll() }
            let unrelated = UUID()
            for id in [scene,unrelated] { _ = try await db.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(id),\(actor),'fixture')").collect() }
            _ = try await db.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(coordinate),\(actor),'read scope',3,'metres')").collect()
            let receiptBox = ImportedReceiptBox()
            try await ServerComposition.live(configuration:config,readHost:host).test(.live) { http in
                for id in [unrelated,scene,UUID()] {
                    let denied = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:headers,body:RunHTTPTestSupport.body(id))
                    XCTAssertEqual(denied.status,.forbidden)
                }
                let response = try await http.executeRequest(uri:"/api/v1/frames/import",method:.post,headers:headers,body:.init(bytes:body))
                XCTAssertEqual(response.status,.created);await receiptBox.store(Data(response.body.readableBytesView))
            }
            let receiptBytes = await receiptBox.data
            let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with:receiptBytes) as? [String:Any])
            let entities = try XCTUnwrap(receipt["entities"] as? [[String:Any]]),first = try XCTUnwrap(entities.first)
            let entity = try XCTUnwrap((first["id"] as? String).flatMap(UUID.init(uuidString:))),source = try XCTUnwrap(first["sourceEventId"] as? String)
            let observed = try XCTUnwrap(receipt["observedAt"] as? String),known = try XCTUnwrap(receipt["knownAt"] as? String)
            let plan = try JSONSerialization.data(withJSONObject:["schemaVersion":"1","tool":"world.get_entity_location@1.0.0","arguments":["schemaVersion":"1","entityId":entity.uuidString,"validAt":observed,"knownAt":known]])
            let answer = try JSONSerialization.data(withJSONObject:["schemaVersion":"1","claims":[["kind":"location","subjectId":entity.uuidString,"locationId":scene.uuidString,"frameId":coordinate.uuidString,"citations":[source]]]])
            let beforeCalls = await model.calls;XCTAssertEqual(beforeCalls,0)
            // Fresh app compositions have no in-memory grant cache. Both resolve
            // the imported subject from its immutable actor-bound observation.
            for _ in 0..<2 {
                await model.configure(plan:plan,answer:answer)
                try await ServerComposition.live(configuration:config,readHost:host).test(.live) { http in
                    let accepted = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:headers,body:RunHTTPTestSupport.body(entity))
                    XCTAssertEqual(accepted.status,.accepted)
                    let path = try XCTUnwrap(accepted.headers[.location]);_ = try await RunHTTPTestSupport.completed(http,token:token,path:path)
                    let response = try await http.executeRequest(uri:path+"/events",method:.get,headers:headers,body:nil)
                    let frames = try RunHTTPTestSupport.frames(response.body);XCTAssertEqual(frames.count,6)
                    let result = try XCTUnwrap(frames[1].1["value"] as? [String:Any]),proofs = try XCTUnwrap(result["evidence"] as? [[String:Any]])
                    XCTAssertEqual(result["status"] as? String,"grounded");XCTAssertEqual(proofs.count,1)
                    XCTAssertEqual((proofs[0]["id"] as? String)?.lowercased(),source.lowercased());XCTAssertEqual(proofs[0]["basis"] as? String,"inferred")
                    XCTAssertEqual(proofs[0]["observedAt"] as? String,observed)
                    let calls = await model.calls;XCTAssertEqual(calls,2)
                }
            }
            for policy in [
                try SyntheticScenePolicy(actorID:UUID(),cameraID:profile.policy.cameraID,locationID:scene,coordinateFrameID:coordinate),
                try SyntheticScenePolicy(actorID:actor,cameraID:UUID(),locationID:scene,coordinateFrameID:coordinate),
                try SyntheticScenePolicy(actorID:actor,cameraID:profile.policy.cameraID,locationID:UUID(),coordinateFrameID:coordinate),
                try SyntheticScenePolicy(actorID:actor,cameraID:profile.policy.cameraID,locationID:scene,coordinateFrameID:UUID())
            ] {
                let permitted = try await PostgresImportedEntityReadScope(client:db,policy:policy).contains(entity,deadline:.now.advanced(by:.seconds(4)))
                XCTAssertFalse(permitted)
            }
            let scope = ReadHostEntityScope(entities:[],imported:PostgresImportedEntityReadScope(client:db,policy:profile.policy))
            let policy = ScopedServerWorldReadPolicy(actorID:actor,scope:scope),definition = try WorldLocationTool.definition()
            for (owner,target,rights) in [(UUID(),"entity:"+entity.uuidString.lowercased(),Set(["world:read"])),(actor,"world:all",Set(["world:read"])),(actor,"entity:"+entity.uuidString.lowercased(),Set(["world:write"]))] {
                let context = ActionPolicyContext(actorID:owner,runID:UUID(),definition:definition,target:target,arguments:Data("{}".utf8),scope:rights,idempotencyKey:"read",deadline:.now.advanced(by:.seconds(4)))
                guard case .deny = try await policy.evaluate(context) else { return XCTFail("Imported scope expanded authority") }
            }
            let fixedHost = try ReadHostConfiguration(models:[model],entities:[PlanningEntity(id:unrelated,label:"explicit")])
            try await ServerComposition.live(configuration:config,readHost:fixedHost).test(.live) { http in
                let response = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:headers,body:RunHTTPTestSupport.body(entity));XCTAssertEqual(response.status,.forbidden)
            }
            var otherCamera = env;otherCamera["SQUIDRA_SYNTHETIC_CAMERA_ID"] = UUID().uuidString
            try await ServerComposition.live(configuration:ServerConfiguration(environment:otherCamera),readHost:host).test(.live) { http in
                let response = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:headers,body:RunHTTPTestSupport.body(entity));XCTAssertEqual(response.status,.forbidden)
            }
        }
    }
    func testCloudHTTPRequiresTransferConsentAndPublishesCapturedSAMProvenance() async throws {
        let env = try Self.environment().filter { !$0.key.hasPrefix("SQUIDRA_SYNTHETIC_") },config = try ServerConfiguration(environment:env)
        let root = Self.fixture.deletingLastPathComponent(),db = config.database.makeClient()
        let capture = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("sam-image-live.v1.json"))) as? [String:Any])
        let report = try XCTUnwrap(capture["report"] as? [String:Any]),transport = HTTPRecordedSAMTransport(text:try XCTUnwrap(report["segmentationText"] as? String))
        let model = try MetaSAMVisionModel(concept:"red square",transport:transport),budget = HTTPRecordedSAMBudget()
        let policy = try FrameScenePolicy(actorID:config.boundary.actorID,cameraID:UUID(),locationID:UUID(),coordinateFrameID:UUID(),cloudIdentity:model.identity)
        let pipeline = try PostgresFrameIngestion(client:db,model:model,policy:policy,cloudAdmission:MetaSAMCloudAdmission(budget:budget))
        let encoded = try Data(contentsOf:root.appendingPathComponent("sam-red-square.png")).base64EncodedString()
        let headers:HTTPFields = [.authorization:"Bearer "+env["SQUIDRA_AUTH_TOKEN"]!,.contentType:"application/json"]
        let actor = policy.actorID,scene = policy.locationID,coordinate = policy.coordinateFrameID
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await db.run() };defer { group.cancelAll() }
            _ = try await db.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(scene),\(actor),'fixture_scene')").collect()
            _ = try await db.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(coordinate),\(actor),'SAM host scene',3,'metres')").collect()
            try await ServerComposition.application(configuration:config,readiness:{.ready},frameImports:FrameImportRoutes(ingestion:pipeline)).test(.router) { http in
                let denied = try await http.executeRequest(uri:"/api/v1/frame-import-capabilities",method:.get,headers:[:],body:nil);XCTAssertEqual(denied.status,.unauthorized)
                let response = try await http.executeRequest(uri:"/api/v1/frame-import-capabilities",method:.get,headers:headers,body:nil)
                XCTAssertEqual(response.status,.ok);XCTAssertEqual(response.headers[.cacheControl],"no-store")
                let capabilities = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(response.body.readableBytesView)) as? [String:Any])
                XCTAssertEqual(capabilities["deployment"] as? String,"cloud");XCTAssertEqual(capabilities["maximumImageBytes"] as? Int,65536);XCTAssertEqual(capabilities["requiresCloudTransferConsent"] as? Bool,true)
                let valid:[String:Any] = ["schemaVersion":"1","imageBase64":encoded,"permitsLocalProcessing":true,"permitsCloudTransfer":true]
                for (changes,status):([String:Any],HTTPResponse.Status) in [(["permitsCloudTransfer":false],.forbidden),(["permitsCloudTransfer":"true"],.badRequest),(["permitsCloudTransfer":NSNull()],.forbidden),(["permitsLocalProcessing":false],.forbidden),(["actorId":UUID().uuidString],.badRequest),(["imageBase64":Data(repeating:0,count:65537).base64EncodedString()],.badRequest)] {
                    let body = try JSONSerialization.data(withJSONObject:valid.merging(changes,uniquingKeysWith:{ _,new in new }))
                    let result = try await http.executeRequest(uri:"/api/v1/frames/import",method:.post,headers:headers,body:.init(bytes:body));XCTAssertEqual(result.status,status)
                }
                var missing = valid;missing.removeValue(forKey:"permitsCloudTransfer")
                let absent = try await http.executeRequest(uri:"/api/v1/frames/import",method:.post,headers:headers,body:.init(bytes:JSONSerialization.data(withJSONObject:missing)));XCTAssertEqual(absent.status,.badRequest)
                let callsBefore = await transport.calls,reservesBefore = await budget.calls;XCTAssertEqual(callsBefore,0);XCTAssertEqual(reservesBefore,0)
                let result = try await http.executeRequest(uri:"/api/v1/frames/import",method:.post,headers:headers,body:.init(bytes:JSONSerialization.data(withJSONObject:valid)))
                XCTAssertEqual(result.status,.created)
                let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(result.body.readableBytesView)) as? [String:Any])
                XCTAssertEqual(receipt["deployment"] as? String,"cloud");XCTAssertEqual(receipt["modelId"] as? String,"meta.sam");XCTAssertEqual(receipt["modelVersion"] as? String,"alias:sam-3.1")
                XCTAssertEqual(receipt["basis"] as? String,"inferred");XCTAssertEqual(receipt["mediaRetained"] as? Bool,false)
                let entities = try XCTUnwrap(receipt["entities"] as? [[String:Any]]);XCTAssertEqual(entities.count,1)
                let entity = try XCTUnwrap((entities[0]["id"] as? String).flatMap(UUID.init(uuidString:)))
                let grant = try await PostgresImportedEntityReadScope(client:db,policy:policy).contains(entity,deadline:.now.advanced(by:.seconds(4)));XCTAssertTrue(grant)
                let calls = await transport.calls,reserves = await budget.calls;XCTAssertEqual(calls,1);XCTAssertEqual(reserves,1)
            }
        }
    }
    func testDefaultProfileDoesNotMountImageImport() async throws {
        let env=try Self.environment().filter {!$0.key.hasPrefix("SQUIDRA_SYNTHETIC_")},config=try ServerConfiguration(environment:env)
        try await ServerComposition.application(configuration:config,readiness:{.ready}).test(.router) { client in
            try await client.execute(uri:"/api/v1/frames/import",method:.post,headers:[.authorization:"Bearer "+env["SQUIDRA_AUTH_TOKEN"]!,.contentType:"application/json"],body:.init(string:"{}")) {XCTAssertEqual($0.status,.notFound)}
        }
    }
}


private actor ImportedQuestionModelFixture: LanguageModel {
    nonisolated let descriptor = ModelDescriptor(id:"fixture.imported-question",modelVersion:"1",location:.local,capabilities:[.text,.structuredOutput])
    private var responses: [Data] = []
    private(set) var calls = 0
    func configure(plan: Data, answer: Data) { responses = [plan,answer];calls = 0 }
    func generate(_ request: ModelRequest) throws -> ModelResponse {
        guard calls < responses.count else { throw ModelProviderError.unavailable }
        let result = responses[calls];calls += 1
        return ModelResponse(requestID:request.id,modelID:descriptor.id,modelVersion:descriptor.modelVersion,text:String(decoding:result,as:UTF8.self),outputTokens:128,costMicroUSD:0)
    }
}

private actor ImportedReceiptBox {
    private(set) var data = Data()
    func store(_ value: Data) { data = value }
}

private actor HTTPRecordedSAMBudget: MetaSAMAttemptBudget {
    private(set) var calls = 0
    func reserveSAM(attemptID: UUID, frameID: UUID, deadline: ContinuousClock.Instant) { calls += 1 }
}
private actor HTTPRecordedSAMTransport: MetaResponsesTransport {
    let text: String
    private(set) var calls = 0
    init(text: String) { self.text = text }
    func post(_ body: Data, maximumResponseBytes: Int, deadline: ContinuousClock.Instant) async throws -> MetaHTTPResponse {
        calls += 1
        return MetaHTTPResponse(status:200,contentType:"application/json",body:try JSONSerialization.data(withJSONObject:["object":"response","model":"sam-3.1","status":"completed","output":[["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":text]]]]]))
    }
}
