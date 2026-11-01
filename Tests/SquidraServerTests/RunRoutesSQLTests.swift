import Foundation
import Hummingbird
import HummingbirdTesting
import PostgresNIO
import SquidraAgentRuntime
import SquidraDomain
import SquidraCognition
import SquidraPostgres
import SquidraProtocols
import XCTest
@testable import SquidraServer

// SAFETY: stateless suite; mutable fixtures are actors, SQL scopes are per scenario.
final class RunRoutesSQLTests: XCTestCase, @unchecked Sendable {
    func testLiveCompositionOwnsReadPipelineAndReportsModelFreeLimitation() async throws {
        try await RunHTTPTestSupport.withClients { client,_ in
            let (fixture,model,_,source) = try await RunHTTPTestSupport.realHarness(client:client)
            let host = try ReadHostConfiguration(models:[model],entities:[PlanningEntity(id:fixture.entity,label:"Allowed fixture entity")])
            try await ServerComposition.live(configuration:fixture.configuration,readHost:host).test(.live) { http in
                let capabilities = try await http.executeRequest(uri:"/api/v1/run-capabilities",method:.get,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                XCTAssertEqual(capabilities.status,.ok)
                XCTAssertEqual(try RunHTTPTestSupport.object(capabilities.body)["textRuns"] as? Bool,true)
                let accepted = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:RunHTTPTestSupport.body(fixture.entity))
                XCTAssertEqual(accepted.status,.accepted)
                let path = try XCTUnwrap(accepted.headers[.location])
                _ = try await RunHTTPTestSupport.completed(http,token:fixture.token,path:path)
                let events = try await http.executeRequest(uri:path+"/events",method:.get,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                let frames = try RunHTTPTestSupport.frames(events.body)
                let answer = try XCTUnwrap(frames[1].1["value"] as? [String:Any])
                let evidence = try XCTUnwrap(answer["evidence"] as? [[String:Any]])
                XCTAssertEqual((evidence.first?["id"] as? String).flatMap(UUID.init(uuidString:)),source)
                let denied = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:RunHTTPTestSupport.body(UUID()))
                XCTAssertEqual(denied.status,.forbidden)
            }
            try await ServerComposition.live(configuration:fixture.configuration).test(.live) { http in
                let anonymous = try await http.executeRequest(uri:"/api/v1/run-capabilities",method:.get,headers:[:],body:nil)
                XCTAssertEqual(anonymous.status,.unauthorized)
                let capabilities = try await http.executeRequest(uri:"/api/v1/run-capabilities",method:.get,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                let value = try RunHTTPTestSupport.object(capabilities.body)
                XCTAssertEqual(value["textRuns"] as? Bool,false)
                XCTAssertEqual(value["limitation"] as? String,"no_configured_read_host")
                let unavailable = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:RunHTTPTestSupport.body(fixture.entity))
                XCTAssertEqual(unavailable.status,.serviceUnavailable)
            }
            let calls = await model.calls;XCTAssertEqual(calls,2)
            await fixture.coordinator.shutdown()
        }
    }
    func testRealEngineHTTPAcceptanceStatusGroundingReplayAndExpiry() async throws {
        try await RunHTTPTestSupport.withClients { client,_ in
            let (fixture,model,reads,source) = try await RunHTTPTestSupport.realHarness(client:client)
            do {
                try await fixture.app().test(.router) { http in
                    let spoof = UUID().uuidString
                    let accepted = try await http.executeRequest(uri:"/api/v1/runs",method:.post,
                        headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json",.init("X-Request-ID")!:spoof],body:RunHTTPTestSupport.body(fixture.entity))
                    XCTAssertEqual(accepted.status,.accepted)
                    XCTAssertEqual(accepted.headers[.cacheControl],"no-store")
                    let result = try RunHTTPTestSupport.object(accepted.body),runText = try XCTUnwrap(result["runId"] as? String),run = try XCTUnwrap(UUID(uuidString:runText))
                    let path = "/api/v1/runs/"+runText,eventPath = path+"/events"
                    XCTAssertEqual(accepted.headers[.location],path)
                    XCTAssertNotEqual(result["requestId"] as? String,spoof)
                    XCTAssertEqual((result["requestId"] as? String).flatMap(UUID.init(uuidString:)),accepted.headers[.init("X-Request-ID")!].flatMap(UUID.init(uuidString:)))
                    let status = try await RunHTTPTestSupport.completed(http,token:fixture.token,path:path)
                    XCTAssertEqual(status["publicationPhase"] as? String,"succeeded");XCTAssertEqual(status["nextSequence"] as? String,"7")
                    XCTAssertEqual((status["runtime"] as? [String:Any])?["state"] as? String,RunState.completed.rawValue)
                    XCTAssertEqual((status["runtime"] as? [String:Any])?["traceId"] as? String,result["traceId"] as? String)
                    XCTAssertNil(status["execution_owner"]);XCTAssertFalse(String(buffer:accepted.body).contains("question"))
                    let stream = try await http.executeRequest(uri:eventPath,method:.get,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                    XCTAssertEqual(stream.status,.ok);XCTAssertEqual(stream.headers[.contentType],"text/event-stream; charset=utf-8")
                    let frames = try RunHTTPTestSupport.frames(stream.body)
                    XCTAssertEqual(frames.count,6)
                    for (index,frame) in frames.enumerated() {
                        let cursor = try AGUIResumeCursor.decode(frame.0)
                        XCTAssertEqual(cursor.actorID,fixture.actor);XCTAssertEqual(cursor.runID,run);XCTAssertEqual(cursor.afterSequence,Int64(index+1))
                    }
                    let proof = try XCTUnwrap(frames[1].1["value"] as? [String:Any]),evidence = try XCTUnwrap(proof["evidence"] as? [[String:Any]])
                    XCTAssertEqual(proof["status"] as? String,"grounded")
                    XCTAssertEqual((evidence.first?["id"] as? String).flatMap(UUID.init(uuidString:)),source)
                    XCTAssertEqual(evidence.first?["confidence"] as? Double,0.8125);XCTAssertEqual(evidence.first?["timeZone"] as? String,"Europe/Paris")
                    XCTAssertNil(evidence.first?["occurredAt"])
                    let resume = try await http.executeRequest(uri:eventPath,method:.get,headers:[.authorization:"Bearer "+fixture.token,.init("Last-Event-ID")!:frames[1].0],body:nil)
                    XCTAssertEqual(try RunHTTPTestSupport.frames(resume.body).map(\.0),frames.dropFirst(2).map(\.0))
                    let caughtUp = try await http.executeRequest(uri:eventPath,method:.get,headers:[.authorization:"Bearer "+fixture.token,.init("Last-Event-ID")!:frames[5].0],body:nil)
                    XCTAssertEqual(Data(caughtUp.body.readableBytesView),AGUIStreamRecord.heartbeat)
                    let future = try AGUIResumeCursor(actorID:fixture.actor,runID:run,afterSequence:7).encoded()
                    let foreign = try AGUIResumeCursor(actorID:UUID(),runID:run,afterSequence:1).encoded()
                    for cursor in [future,foreign,"malformed"] {
                        let response = try await http.executeRequest(uri:eventPath,method:.get,headers:[.authorization:"Bearer "+fixture.token,.init("Last-Event-ID")!:cursor],body:nil)
                        XCTAssertEqual(response.status,.badRequest);XCTAssertFalse(String(buffer:response.body).contains("RUN_ERROR"))
                    }
                    let absent = try await http.executeRequest(uri:"/api/v1/runs/"+UUID().uuidString+"/events",method:.get,
                        headers:[.authorization:"Bearer "+fixture.token,.init("Last-Event-ID")!:"malformed"],body:nil)
                    XCTAssertEqual(absent.status,.notFound)
                    let denied = try await http.executeRequest(uri:path,method:.get,headers:[.authorization:"Bearer "+fixture.token,.init("X-Actor-ID")!:UUID().uuidString],body:nil)
                    XCTAssertEqual(denied.status,.forbidden);XCTAssertFalse(String(buffer:denied.body).contains("private-canary"))
                    let lateCancellation = try await http.executeRequest(uri:path+"/cancel",method:.post,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                    XCTAssertEqual(lateCancellation.status,.ok)
                    XCTAssertEqual(try RunHTTPTestSupport.object(lateCancellation.body)["publicationPhase"] as? String,"succeeded")
                    let modelCalls = await model.calls,readCalls = await reads.calls
                    XCTAssertEqual(modelCalls,2);XCTAssertEqual(readCalls,1)
                    _ = try await client.query("UPDATE run_event_streams SET created_at=clock_timestamp()-interval '3 hours',execution_lease_until=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE run_id=\(run)").collect()
                    for uri in [path,eventPath] {
                        let expired = try await http.executeRequest(uri:uri,method:.get,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                        XCTAssertEqual(expired.status,.gone);XCTAssertEqual(try RunHTTPTestSupport.object(expired.body)["code"] as? String,"EXPIRED")
                    }
                    let unchangedCalls = await model.calls;XCTAssertEqual(unchangedCalls,2)
                }
            } catch { await fixture.coordinator.shutdown();throw error }
            await fixture.coordinator.shutdown()
        }
    }
    func testAuthenticationClosedBodiesAuthorityAndLastEventIDPreflight() async throws {
        try await RunHTTPTestSupport.withClients { client,_ in
            let executor = HTTPGatedAnswerFixture(),fixture = try RunHTTPTestSupport.harness(client:client,executor:executor)
            do {
                try await fixture.app().test(.router) { http in
                    let valid = try RunHTTPTestSupport.body(fixture.entity)
                    let unauthenticated = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:[.contentType:"application/json"],body:valid)
                    XCTAssertEqual(unauthenticated.status,.unauthorized)
                    let wrongOrigin = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json",.origin:"https://foreign.example"],body:valid)
                    XCTAssertEqual(wrongOrigin.status,.forbidden)
                    let preflight = try await http.executeRequest(uri:"/api/v1/runs/"+UUID().uuidString+"/events",method:.options,
                        headers:[.origin:"http://localhost:3000",.accessControlRequestMethod:"GET",.accessControlRequestHeaders:"authorization,last-event-id"],body:nil)
                    XCTAssertEqual(preflight.status,.noContent);XCTAssertTrue(preflight.headers[.accessControlAllowHeaders]?.contains("Last-Event-ID") == true)
                    let rejectedPreflight = try await http.executeRequest(uri:"/api/v1/runs",method:.options,
                        headers:[.origin:"http://localhost:3000",.accessControlRequestMethod:"POST",.accessControlRequestHeaders:"x-unknown"],body:nil)
                    XCTAssertEqual(rejectedPreflight.status,.forbidden)
                    let entity = fixture.entity.uuidString
                    let invalid = [
                        "{\"schemaVersion\":\"1\",\"entityId\":\"\(entity)\",\"intent\":\"current\",\"question\":\"x\",\"actorId\":\"\(UUID())\"}",
                        "{\"schemaVersion\":\"1\",\"entityId\":\"\(entity)\",\"intent\":\"current\",\"question\":\"x\",\"scope\":[\"admin\"]}",
                        "{\"schemaVersion\":\"1\",\"entityId\":\"\(entity)\",\"intent\":\"current\",\"question\":\"x\",\"question\":\"y\"}",
                        "{\"schemaVersion\":1,\"entityId\":\"\(entity)\",\"intent\":\"current\",\"question\":\"x\"}",
                        "{\"schemaVersion\":\"1\",\"entityId\":\"\(entity)\",\"intent\":\"future\",\"question\":\"x\"}",
                        "{\"schemaVersion\":\"1\",\"entityId\":\"\(entity)\",\"intent\":\"current\",\"question\":null}",
                        "{\"schemaVersion\":\"1\",\"entityId\":\"\(entity)\",\"intent\":\"current\",\"question\":\"\(String(repeating:"x",count:4097))\"}"]
                    for body in invalid {
                        let response = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:.init(string:body))
                        XCTAssertEqual(response.status,.badRequest)
                    }
                    let oversized = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:.init(string:String(repeating:"x",count:40_000)))
                    XCTAssertEqual(oversized.status,.contentTooLarge)
                    let foreign = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:RunHTTPTestSupport.body(UUID()))
                    XCTAssertEqual(foreign.status,.forbidden)
                    let unavailable = try await fixture.app(submit:false).test(.router) { other in
                        try await other.executeRequest(uri:"/api/v1/runs",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:valid)
                    }
                    XCTAssertEqual(unavailable.status,.serviceUnavailable);XCTAssertEqual(try RunHTTPTestSupport.object(unavailable.body)["code"] as? String,"UNAVAILABLE")
                    let rows = try await client.query("SELECT count(*) FROM run_event_streams WHERE actor_id=\(fixture.actor)").collect()
                    XCTAssertEqual(try XCTUnwrap(rows.first).decode(Int64.self),0)
                    let calls = await executor.calls;XCTAssertEqual(calls,0)
                }
            } catch { await fixture.coordinator.shutdown();throw error }
            await fixture.coordinator.shutdown()
        }
    }
    func testHTTPCancellationPersistsRuntimeAndPublicationDuringModelAndToolCalls() async throws {
        try await RunHTTPTestSupport.withClients { client,readback in
            for stage in 0..<3 {
                let (fixture,model,reads,_) = try await RunHTTPTestSupport.realHarness(client:client,pauseOnModelCall:stage == 1 ? nil : (stage == 0 ? 1 : 2),pauseOnRead:stage == 1)
                do {
                    try await fixture.app().test(.router) { http in
                        let accepted = try await http.executeRequest(uri:"/api/v1/runs",method:.post,
                            headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:RunHTTPTestSupport.body(fixture.entity))
                        XCTAssertEqual(accepted.status,.accepted)
                        let runText = try XCTUnwrap(RunHTTPTestSupport.object(accepted.body)["runId"] as? String),run = try XCTUnwrap(UUID(uuidString:runText))
                        let path = "/api/v1/runs/"+runText
                        if stage == 1 { try await RunHTTPTestSupport.wait { await reads.calls == 1 } }
                        else { try await RunHTTPTestSupport.wait { await model.calls == (stage == 0 ? 1 : 2) } }
                        let response = try await http.executeRequest(uri:path+"/cancel",method:.post,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                        XCTAssertEqual(response.status,.accepted)
                        try await RunHTTPTestSupport.wait { await fixture.coordinator.activeCount == 0 }
                        let durable = try await PostgresRunStore(client:readback).load(actorID:fixture.actor,runID:run,deadline:.now.advanced(by:.seconds(4)))
                        XCTAssertEqual(durable.state,.cancelled);XCTAssertEqual(durable.terminalCode,.cancelled)
                        let status = try await http.executeRequest(uri:path,method:.get,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                        let value = try RunHTTPTestSupport.object(status.body)
                        XCTAssertEqual(value["publicationPhase"] as? String,"cancelled");XCTAssertEqual(value["outputReady"] as? Bool,false)
                        XCTAssertEqual((value["runtime"] as? [String:Any])?["state"] as? String,RunState.cancelled.rawValue)
                        let stream = try await http.executeRequest(uri:path+"/events",method:.get,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                        let frames = try RunHTTPTestSupport.frames(stream.body)
                        XCTAssertEqual(frames.count,2);XCTAssertEqual(frames.last?.1["type"] as? String,"RUN_FINISHED")
                        let modelCalls = await model.calls,readCalls = await reads.calls
                        XCTAssertEqual(modelCalls,stage == 2 ? 2 : 1);XCTAssertEqual(readCalls,stage == 0 ? 0 : 1)
                    }
                } catch { await fixture.coordinator.shutdown();throw error }
                await fixture.coordinator.shutdown()
            }
        }
    }
    func testAuthenticatedCancellationIsDurableAndTerminalRepeatsAreIdempotent() async throws {
        try await RunHTTPTestSupport.withClients { client,_ in
            let executor = HTTPGatedAnswerFixture(),fixture = try RunHTTPTestSupport.harness(client:client,executor:executor)
            do {
                try await fixture.app().test(.router) { http in
                    let accepted = try await http.executeRequest(uri:"/api/v1/runs",method:.post,
                        headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:RunHTTPTestSupport.body(fixture.entity))
                    let run = try XCTUnwrap(RunHTTPTestSupport.object(accepted.body)["runId"] as? String),path = "/api/v1/runs/"+run
                    try await RunHTTPTestSupport.wait { await executor.calls == 1 }
                    let anonymous = try await http.executeRequest(uri:path+"/cancel",method:.post,headers:[:],body:nil)
                    XCTAssertEqual(anonymous.status,.unauthorized)
                    let foreign = try await http.executeRequest(uri:path+"/cancel",method:.post,
                        headers:[.authorization:"Bearer "+fixture.token,.init("X-Actor-ID")!:UUID().uuidString],body:nil)
                    XCTAssertEqual(foreign.status,.forbidden)
                    for suffix in ["/cancel?force=true","/cancel"] {
                        let invalid = try await http.executeRequest(uri:path+suffix,method:.post,
                            headers:[.authorization:"Bearer "+fixture.token],body:suffix.contains("?") ? nil : .init(string:"{}"))
                        XCTAssertEqual(invalid.status,.badRequest)
                    }
                    let untouched = await executor.cancellations;XCTAssertEqual(untouched,0)
                    let cancellation = try await http.executeRequest(uri:path+"/cancel",method:.post,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                    XCTAssertEqual(cancellation.status,.accepted)
                    try await RunHTTPTestSupport.wait { await fixture.coordinator.activeCount == 0 }
                    let status = try await http.executeRequest(uri:path,method:.get,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                    XCTAssertEqual(try RunHTTPTestSupport.object(status.body)["publicationPhase"] as? String,"cancelled")
                    for _ in 0..<2 {
                        let repeated = try await http.executeRequest(uri:path+"/cancel",method:.post,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                        XCTAssertEqual(repeated.status,.ok)
                        XCTAssertEqual(try RunHTTPTestSupport.object(repeated.body)["publicationPhase"] as? String,"cancelled")
                    }
                    let absent = try await http.executeRequest(uri:"/api/v1/runs/"+UUID().uuidString+"/cancel",method:.post,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                    XCTAssertEqual(absent.status,.notFound)
                    let orphan = AGUIRunBinding(actorID:fixture.actor,runID:UUID(),threadID:UUID(),requestID:UUID())
                    _ = try await fixture.events.create(orphan,retentionSeconds:3600,deadline:.now.advanced(by:.seconds(4)))
                    _ = try await fixture.publication.claim(orphan,maximumExecutionSeconds:60,at:RunHTTPTestSupport.clock.now(),deadline:.now.advanced(by:.seconds(4)))
                    let orphanCancellation = try await http.executeRequest(uri:"/api/v1/runs/"+orphan.runID.uuidString+"/cancel",method:.post,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                    XCTAssertEqual(orphanCancellation.status,.conflict)
                    let orphanStatus = try await fixture.publication.status(actorID:fixture.actor,runID:orphan.runID,deadline:.now.advanced(by:.seconds(4)))
                    XCTAssertEqual(orphanStatus.phase,.running)
                    let calls = await executor.calls,cancellations = await executor.cancellations
                    XCTAssertEqual(calls,1);XCTAssertEqual(cancellations,1)
                }
            } catch { await fixture.coordinator.shutdown();throw error }
            await fixture.coordinator.shutdown()
        }
    }
    func testLiveLongPollDisconnectAndReconnectNeverOwnWorkerLifetime() async throws {
        let client = try RunHTTPTestSupport.client(),other = try RunHTTPTestSupport.client(),executor = HTTPGatedAnswerFixture()
        let fixture = try RunHTTPTestSupport.harness(client:client,executor:executor)
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await other.run() };defer { group.cancelAll() }
            try await fixture.app(ownClient:true,wait:.seconds(2)).test(.ahc()) { http in
                let accepted = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:RunHTTPTestSupport.body(fixture.entity))
                XCTAssertEqual(accepted.status,.accepted)
                let run = try XCTUnwrap(RunHTTPTestSupport.object(accepted.body)["runId"] as? String),path = "/api/v1/runs/"+run
                try await RunHTTPTestSupport.wait { await executor.calls == 1 }
                let first = try await http.executeRequest(uri:path+"/events",method:.get,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                let frames = try RunHTTPTestSupport.frames(first.body);XCTAssertEqual(frames.count,1)
                let cursor = try XCTUnwrap(frames.first?.0),before = await fixture.replay.pages
                let disconnected = Task { try await http.executeRequest(uri:path+"/events",method:.get,headers:[.authorization:"Bearer "+fixture.token,.init("Last-Event-ID")!:cursor],body:nil) }
                try await RunHTTPTestSupport.wait { await fixture.replay.pages > before }
                disconnected.cancel()
                var requestWasCancelled = false
                do { _ = try await disconnected.value } catch { requestWasCancelled = true }
                XCTAssertTrue(requestWasCancelled)
                let calls = await executor.calls,cancelled = await executor.cancellations
                XCTAssertEqual(calls,1);XCTAssertEqual(cancelled,0)
                await executor.release()
                _ = try await RunHTTPTestSupport.completed(http,token:fixture.token,path:path)
                let replay = try await http.executeRequest(uri:path+"/events",method:.get,headers:[.authorization:"Bearer "+fixture.token,.init("Last-Event-ID")!:cursor],body:nil)
                XCTAssertEqual(try RunHTTPTestSupport.frames(replay.body).count,5)
                let noRepeat = await executor.calls;XCTAssertEqual(noRepeat,1)
            }
            let accepting = await fixture.coordinator.isAccepting,active = await fixture.coordinator.activeCount
            XCTAssertFalse(accepting);XCTAssertEqual(active,0)
        }
    }
    func testLiveShutdownJoinsCancelledPublicationBeforeDatabaseClientStops() async throws {
        let client = try RunHTTPTestSupport.client(),other = try RunHTTPTestSupport.client(),executor = HTTPGatedAnswerFixture()
        let fixture = try RunHTTPTestSupport.harness(client:client,executor:executor)
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await other.run() };defer { group.cancelAll() }
            let run = try await fixture.app(ownClient:true).test(.live) { http -> UUID in
                let accepted = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:RunHTTPTestSupport.body(fixture.entity))
                XCTAssertEqual(accepted.status,.accepted)
                let run = try XCTUnwrap((RunHTTPTestSupport.object(accepted.body)["runId"] as? String).flatMap(UUID.init(uuidString:)))
                try await RunHTTPTestSupport.wait { await executor.calls == 1 }
                return run
            }
            let status = try await PostgresRunPublicationStore(client:other,actorID:fixture.actor).status(actorID:fixture.actor,runID:run,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(status.phase,.cancelled);XCTAssertTrue(status.stream.isTerminal)
            let active = await fixture.coordinator.activeCount,cancellations = await executor.cancellations
            XCTAssertEqual(active,0);XCTAssertEqual(cancellations,1)
        }
    }
}
