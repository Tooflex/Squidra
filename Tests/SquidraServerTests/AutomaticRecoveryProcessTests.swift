import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Hummingbird
import PostgresNIO
import SquidraAgentRuntime
import SquidraCognition
import SquidraDomain
import SquidraPostgres
import SquidraTemporal
import XCTest
@testable import SquidraServer

// SAFETY: stateless test; each scenario owns its child processes and private files.
final class AutomaticRecoveryProcessTests: XCTestCase, @unchecked Sendable {
    private struct Manifest: Decodable { let actor:UUID,run:UUID,version:Int64 }
    private enum Failure: Error { case process, timeout, response, unexpectedModelCall }
    private actor Model: LanguageModel {
        nonisolated let descriptor = ModelDescriptor(id:"authored-crash",modelVersion:"1",location:.local,capabilities:[.text,.structuredOutput])
        let entity:UUID,at:String,answerOnly:Bool,maximumCalls:Int,counter:URL
        var calls = 0
        init(entity:UUID,answerOnly:Bool,maximumCalls:Int,counter:URL) throws {
            self.entity = entity;self.answerOnly = answerOnly;self.maximumCalls = maximumCalls;self.counter = counter
            at = try RFC3339.format(UTCInstant(secondsSince1970:Date().timeIntervalSince1970))
            try Data("0".utf8).write(to:counter,options:.atomic)
        }
        func generate(_ request:ModelRequest) throws -> ModelResponse {
            calls += 1;try Data(String(calls).utf8).write(to:counter,options:.atomic)
            guard calls <= maximumCalls else { throw Failure.unexpectedModelCall }
            let fields:[String:Any]
            if calls == 1 && !answerOnly {
                fields = ["schemaVersion":"1","tool":"world.get_entity_location@1.0.0","arguments":["schemaVersion":"1","entityId":entity.uuidString,"validAt":at,"knownAt":at]]
            } else { fields = ["schemaVersion":"1","claims":[["kind":"unknown","subjectId":entity.uuidString,"citations":[]]]] }
            return ModelResponse(requestID:request.id,modelID:descriptor.id,modelVersion:descriptor.modelVersion,
                text:String(decoding:try JSONSerialization.data(withJSONObject:fields),as:UTF8.self),outputTokens:64,costMicroUSD:0)
        }
    }
    private static func wait(_ condition:() throws -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by:.seconds(12))
        while !(try condition()) { guard ContinuousClock.now < end else { throw Failure.timeout };try await Task.sleep(for:.milliseconds(20)) }
    }
    private static func spawn(_ executable:URL,_ args:[String],_ env:[String:String],_ log:URL) throws -> Process {
        FileManager.default.createFile(atPath:log.path,contents:nil)
        let output = try FileHandle(forWritingTo:log);defer { try? output.close() }
        let process = Process();process.executableURL = executable;process.arguments = args;process.environment = env
        process.standardOutput = output;process.standardError = output
        try process.run();return process
    }
    private static func stop(_ process:Process,kill abruptly:Bool) async throws {
        guard process.isRunning else { throw Failure.process }
        guard kill(process.processIdentifier,abruptly ? SIGKILL : SIGTERM) == 0 else { throw Failure.process }
        try await wait { !process.isRunning }
        if abruptly { guard process.terminationReason == .uncaughtSignal,process.terminationStatus == SIGKILL else { throw Failure.process } }
        else { guard process.terminationReason == .exit,process.terminationStatus == 0 else { throw Failure.process } }
    }
    private static func report(_ log:URL,_ environment:[String:String]) {
        var text = (try? String(contentsOf:log,encoding:.utf8)) ?? "No child log"
        for (key,value) in environment where key.contains("PASSWORD") || key.contains("TOKEN") {
            if !value.isEmpty { text = text.replacingOccurrences(of:value,with:"[REDACTED]") }
        }
        print(String(text.suffix(4000)))
    }
    private static func emergencyStop(_ process:Process) {
        if process.isRunning { _ = kill(process.processIdentifier,SIGKILL);process.waitUntilExit() }
    }
    private static func get(_ port:Int,_ path:String,_ token:String) async throws -> Data {
        var request = URLRequest(url:URL(string:"http://127.0.0.1:\(port)"+path)!)
        request.timeoutInterval = 5;request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        let (data,response) = try await URLSession.shared.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,!String(decoding:data,as:UTF8.self).contains(token) else { throw Failure.response }
        return data
    }
    private static func hashes(_ client:PostgresClient,_ m:Manifest) async throws -> [String] {
        let rows = try await client.query("""
            SELECT COALESCE((SELECT md5(archive) FROM read_run_plans WHERE actor_id=\(m.actor) AND run_id=\(m.run)),''),
                COALESCE((SELECT md5(payload)||call_id::text FROM read_run_tool_results WHERE actor_id=\(m.actor) AND run_id=\(m.run)),''),
                COALESCE((SELECT md5(archive) FROM read_run_answers WHERE actor_id=\(m.actor) AND run_id=\(m.run)),''),
                COALESCE((SELECT md5(answer) FROM read_run_completions WHERE actor_id=\(m.actor) AND run_id=\(m.run)),'')
            """).collect()
        let (plan,result,answer,completion) = try XCTUnwrap(rows.first).decode((String,String,String,String).self)
        return [plan,result,answer,completion]
    }
    func testAutomaticHostRecoveryAfterSIGKILL() async throws {
        let env = ProcessInfo.processInfo.environment
        if env["SQUIDRA_TEST_RECOVERY_CHILD"] == "1" {
            let manifest = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:URL(fileURLWithPath:try XCTUnwrap(env["SQUIDRA_TEST_RECOVERY_MANIFEST"]))))
            try await RunHTTPTestSupport.withClients { client,_ in
                let loaded = try await PostgresReadRunTaskStore(client:client,actorID:manifest.actor).load(runID:manifest.run,deadline:.now.advanced(by:.seconds(4)))
                let task = try XCTUnwrap(loaded)
                let mode = try XCTUnwrap(env["SQUIDRA_TEST_RECOVERY_MODE"]),replay = env["SQUIDRA_TEST_RECOVERY_REPLAY"] == "1"
                let expected = replay ? 0 : (mode == "seed-early" ? 2 : (["seed-plan","seed-result"].contains(mode) ? 1 : 0))
                let model = try Model(entity:XCTUnwrap(task.request.planningScope.entities.first?.id),answerOnly:mode != "seed-early",maximumCalls:expected,
                    counter:URL(fileURLWithPath:try XCTUnwrap(env["SQUIDRA_TEST_RECOVERY_COUNTER"])))
                let ownership = try LocalRunOwnership.acquire(directory:URL(fileURLWithPath:try XCTUnwrap(env["SQUIDRA_RUN_DIRECTORY"])),actorID:manifest.actor)
                defer { ownership.releaseAfterJoiningWorkers() }
                let config = try ServerConfiguration(environment:env)
                let host = try ReadHostConfiguration(models:[model],entities:task.request.planningScope.entities)
                try await ServerComposition.live(configuration:config,readHost:host,localOwnership:ownership).runService()
            }
            return
        }
        #if canImport(Darwin)
        let bundle = Bundle(for:Self.self).bundleURL
        let products = bundle.deletingLastPathComponent()
        let hostExecutable = URL(fileURLWithPath:CommandLine.arguments[0])
        let hostArgs = ["-XCTest","SquidraServerTests.AutomaticRecoveryProcessTests/testAutomaticHostRecoveryAfterSIGKILL",bundle.path]
        #else
        let hostExecutable = URL(fileURLWithPath:CommandLine.arguments[0])
        let products = hostExecutable.deletingLastPathComponent()
        let hostArgs = ["SquidraServerTests.AutomaticRecoveryProcessTests/testAutomaticHostRecoveryAfterSIGKILL"]
        #endif
        let seedExecutable = products.appendingPathComponent("squidra-publication-crash-fixture")
        guard FileManager.default.isExecutableFile(atPath:seedExecutable.path) else { throw Failure.process }
        try await RunHTTPTestSupport.withClients { client,_ in
            for mode in ["seed-early","seed-plan","seed-result","seed-answer","seed-completion"] {
                print("Automatic recovery boundary: "+mode)
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("squidra-auto-crash-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                defer { try? FileManager.default.removeItem(at:temp) }
                let marker = temp.appendingPathComponent("manifest.json"),directory = temp.appendingPathComponent("ownership")
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                var seedEnv = env;seedEnv["SQUIDRA_PUBLICATION_CRASH_FIXTURE"] = "1";seedEnv["SQUIDRA_RUN_DIRECTORY"] = directory.path
                let seed = try Self.spawn(seedExecutable,[mode,marker.path],seedEnv,temp.appendingPathComponent("seed.log"))
                defer { Self.emergencyStop(seed) }
                try await Self.wait { guard seed.isRunning else { Self.report(temp.appendingPathComponent("seed.log"),seedEnv);throw Failure.process };return FileManager.default.fileExists(atPath:marker.path) }
                let manifest = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:marker))
                try await Self.stop(seed,kill:true)
                let original = try await PostgresRunStore(client:client).load(actorID:manifest.actor,runID:manifest.run,deadline:.now.advanced(by:.seconds(4)))
                XCTAssertEqual(original.version,manifest.version)
                let saved = try await Self.hashes(client,manifest)
                let token = (UUID().uuidString.replacingOccurrences(of:"-",with:"")+UUID().uuidString.replacingOccurrences(of:"-",with:"")).lowercased()
                var hostEnv = seedEnv
                hostEnv.merge(["SQUIDRA_TEST_RECOVERY_CHILD":"1","SQUIDRA_TEST_RECOVERY_MANIFEST":marker.path,"SQUIDRA_TEST_RECOVERY_MODE":mode,
                    "SQUIDRA_PORT":"0","SQUIDRA_ACTOR_ID":manifest.actor.uuidString,"SQUIDRA_AUTH_TOKEN":token,"SQUIDRA_UI_ORIGIN":"http://localhost:3000",
                    "SQUIDRA_DB_PORT":try XCTUnwrap(env["SQUIDRA_TEST_DB_PORT"]),"SQUIDRA_DB_USER":"squidra","SQUIDRA_DB_NAME":"squidra",
                    "SQUIDRA_DB_PASSWORD":try XCTUnwrap(env["SQUIDRA_TEST_DB_PASSWORD"])],uniquingKeysWith:{ _,new in new })
                var first:Data?,completed:RunSnapshot?
                for replay in [false,true] {
                    let counter = temp.appendingPathComponent(replay ? "second.count" : "first.count"),log = temp.appendingPathComponent(replay ? "second.log" : "first.log")
                    hostEnv["SQUIDRA_TEST_RECOVERY_COUNTER"] = counter.path;hostEnv["SQUIDRA_TEST_RECOVERY_REPLAY"] = replay ? "1" : "0"
                    let host = try Self.spawn(hostExecutable,hostArgs,hostEnv,log)
                    defer { Self.emergencyStop(host) }
                    var port:Int?
                    try await Self.wait {
                        guard host.isRunning else { Self.report(log,hostEnv);throw Failure.process }
                        let lines = try String(contentsOf:log,encoding:.utf8).split(separator:"\n")
                        port = lines.first(where:{ $0.hasPrefix("SQUIDRA listening 127.0.0.1:") }).flatMap { Int($0.split(separator:":").last ?? "") }
                        return port != nil
                    }
                    let httpPort = try XCTUnwrap(port),path = "/api/v1/runs/"+manifest.run.uuidString
                    let ready = try JSONSerialization.jsonObject(with:await Self.get(httpPort,"/ready",token)) as? [String:String]
                    XCTAssertEqual(ready,["status":"ready"])
                    try await RunHTTPTestSupport.wait {
                        (try? await PostgresRunPublicationStore(client:client,actorID:manifest.actor).status(actorID:manifest.actor,runID:manifest.run,deadline:.now.advanced(by:.seconds(4))))?.phase == .succeeded
                    }
                    let state = try await PostgresRunStore(client:client).load(actorID:manifest.actor,runID:manifest.run,deadline:.now.advanced(by:.seconds(4)))
                    XCTAssertEqual(state.state,.completed);XCTAssertEqual(state.calls,1);XCTAssertEqual(state.steps,1)
                    XCTAssertEqual(state.budget,original.budget);XCTAssertEqual(state.traceID,original.traceID)
                    XCTAssertGreaterThan(state.version,original.version)
                    if let completed { XCTAssertEqual(state,completed) } else { completed = state }
                    let after = try await Self.hashes(client,manifest)
                    for index in saved.indices where !saved[index].isEmpty { XCTAssertEqual(after[index],saved[index]) }
                    let body = try await Self.get(httpPort,path+"/events",token)
                    XCTAssertEqual(String(decoding:body,as:UTF8.self).components(separatedBy:"data: ").count-1,6)
                    if let first { XCTAssertEqual(body,first) } else { first = body }
                    let count = try Int(String(contentsOf:counter,encoding:.utf8))
                    let calls = replay ? 0 : (mode == "seed-early" ? 2 : (["seed-plan","seed-result"].contains(mode) ? 1 : 0))
                    XCTAssertEqual(count,calls)
                    if !replay {
                        let trace = try JSONSerialization.jsonObject(with:await Self.get(httpPort,path+"/trace",token)) as? [String:Any]
                        let spans = try XCTUnwrap(trace?["spans"] as? [[String:Any]])
                        XCTAssertEqual(spans.filter { $0["stage"] as? String == "model" }.count,calls)
                        XCTAssertEqual(spans.filter { $0["stage"] as? String == "tool" }.count,["seed-early","seed-plan"].contains(mode) ? 1 : 0)
                    }
                    try await Self.stop(host,kill:!replay)
                }
            }
        }
    }
}
