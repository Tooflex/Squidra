import Foundation
import Hummingbird
import HummingbirdTesting
import PostgresNIO
import SquidraDomain
import SquidraPostgres
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
    func testDefaultProfileDoesNotMountImageImport() async throws {
        let env=try Self.environment().filter {!$0.key.hasPrefix("SQUIDRA_SYNTHETIC_")},config=try ServerConfiguration(environment:env)
        try await ServerComposition.application(configuration:config,readiness:{.ready}).test(.router) { client in
            try await client.execute(uri:"/api/v1/frames/import",method:.post,headers:[.authorization:"Bearer "+env["SQUIDRA_AUTH_TOKEN"]!,.contentType:"application/json"],body:.init(string:"{}")) {XCTAssertEqual($0.status,.notFound)}
        }
    }
}
