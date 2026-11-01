import Foundation
import Hummingbird
import HummingbirdTesting
import PostgresNIO
import SquidraAgentRuntime
import SquidraDomain
import SquidraCognition
import SquidraMemory
import SquidraPerception
import SquidraSpatial
import SquidraWorld
import SquidraObservability
import SquidraPostgres
import SquidraProtocols
import SquidraTools
import XCTest
@testable import SquidraServer

// SAFETY: stateless suite; mutable fixtures are actors, SQL scopes are per scenario.
final class RunRoutesSQLTests: XCTestCase, @unchecked Sendable {
    static func report(actor: UUID, entity: UUID, unknownFinalConfidence: Bool = false) throws -> MovementReport {
        let frame = try SpatialCoordinateFrame(actorID: actor,id: UUID(),up: .positiveZ,calibration: SpatialCalibration(id: UUID(),version: "fixture-1",maximumErrorMeters: 0))
        let camera = UUID()
        let samples = try [0.0,0.2,0.2,0.2,0.5,0.5,0.5].enumerated().map { i,x in
            let time = try UTCInstant(secondsSince1970: 1_700_000_000+Double(i))
            let source = try SpatialSource(observationID: UUID(),cameraID: camera,imageFrameID: UUID(),modelID: "authored-scene",modelVersion: "1",
                times: ObservationTimestamps(occurredAt: nil,observedAt: time,recordedAt: time,timeZone: IANATimeZone(identifier: "Europe/Paris")),
                confidence: unknownFinalConfidence && i == 6 ? nil : Confidence(0.8))
            return try MovementSample(observedAt: time,observation: SpatialObservation(actorID: actor,entityID: entity,coordinateFrameID: frame.id,
                geometry: .calibrated3D(SpatialBox3D(lower: [x,0,0],upper: [x+0.1,0.1,0.1],maximumErrorMeters: 0)),association: .confirmed,
                validity: SpatialValidity(from: time,to: nil),source: source),frame: frame)
        }
        return try ConfirmedMovementDetector(actorID: actor,entityID: entity,epochID: UUID(),entityType: "cup",
            policy: MovementPolicy(id: UUID(),thresholdsByType: ["cup": MovementThreshold(minimumDisplacementMeters: 0.1)])).evaluate(samples)
    }
    func testLiveServerRecoversCompletedArchiveWithoutModelOrDuplicatePublication() async throws {
        try await RunHTTPTestSupport.withClients { client,second in
            for concurrent in [true,false] {
            let actor = UUID(),entity = UUID(),clock = try RunHTTPTestSupport.clock
            let config = try RunHTTPTestSupport.configuration(actor:actor,token:String(repeating:"b",count:64))
            let at = try clock.now(),request = try ReadRunRequest(actorID:actor,question:"Where is the fixture?",
                planningScope:ReadPlanningScope(entities:[PlanningEntity(id:entity,label:"Fixture")]),effectiveToolScope:["world:read"],intent:.historical,
                modelOptions:ReadPlanningOptions(deadline:UTCInstant(secondsSince1970:at.secondsSince1970+120)))
            let binding = AGUIRunBinding(actorID:actor,runID:request.runID,threadID:UUID(),requestID:request.requestID)
            let events = PostgresRunEventStore(client:client,actorID:actor),publication = PostgresRunPublicationStore(client:client,actorID:actor)
            _ = try await events.create(binding,retentionSeconds:3600,deadline:.now.advanced(by:.seconds(4)))
            try await PostgresReadRunTaskStore(client:client,actorID:actor).save(StoredReadRunTask(request:request,threadID:binding.threadID),deadline:.now.advanced(by:.seconds(4)))
            let claim = try await publication.claim(binding,maximumExecutionSeconds:120,at:at,deadline:.now.advanced(by:.seconds(4)))
            let runtime = PostgresRunStore(client:client)
            let controller = try await RunController.create(actorID:actor,id:request.runID,traceID:request.traceID,store:runtime,clock:clock)
            _ = try await controller.transition(to:.validating)
            _ = try await controller.transition(to:.contextLoading)
            _ = try await controller.transition(to:.planning)
            _ = try await controller.validatedProposal(semanticDigest:String(repeating:"a",count:64),invocationKey:"recovery-fixture")
            _ = try await controller.transition(to:.responding)
            let context = try AnswerEvidenceContext(snapshot:WorldStateSnapshot(actorID:actor,subjectID:entity,validAt:at,knownAt:at,facts:[],projectedThroughSequence:0,availableThroughSequence:0),expectedActor:actor,intent:.historical,
                clock:clock,policy:AnswerFreshnessPolicy(maximumObservationAgeSeconds:60,minimumCurrentConfidence:Confidence(0.5)))
            let text = String(decoding:try JSONSerialization.data(withJSONObject:["schemaVersion":"1","claims":[["kind":"unknown","subjectId":entity.uuidString,"citations":[]]]]),as:UTF8.self)
            let answer = try GroundedAnswerValidator().validate(ModelResponse(requestID:request.requestID,modelID:"authored-fixture",modelVersion:"1",text:text,outputTokens:1,costMicroUSD:0),expectedRequestID:request.requestID,context:context)
            try await PostgresReadRunCompletionStore(client:client,actorID:actor).save(snapshot:controller.snapshot(),answer:answer,deadline:.now.advanced(by:.seconds(4)))
            // Expiry alone cannot turn an unfinished runtime into a success.
            _ = try await client.query("UPDATE run_event_streams SET created_at=clock_timestamp()-interval '2 hours',execution_lease_until=clock_timestamp()-interval '1 hour' WHERE run_id=\(request.runID)").collect()
            let unfinished = try await publication.recoverNextCompleted(at:clock.now(),deadline:.now.advanced(by:.seconds(4)))
            XCTAssertFalse(unfinished)
            _ = try await controller.finishIteration(progress:.validatedResponse)
            _ = try await controller.transition(to:.completed,terminalCode:.completed)
            let foreign = try await PostgresRunPublicationStore(client:second,actorID:UUID()).recoverNextCompleted(at:clock.now(),deadline:.now.advanced(by:.seconds(4)))
            XCTAssertFalse(foreign)
            if concurrent {
                async let one = publication.recoverNextCompleted(at:clock.now(),deadline:.now.advanced(by:.seconds(4)))
                async let two = PostgresRunPublicationStore(client:second,actorID:actor).recoverNextCompleted(at:clock.now(),deadline:.now.advanced(by:.seconds(4)))
                let winners = try await [one,two]
                XCTAssertEqual(winners.filter { $0 }.count,1)
            }
            try await ServerComposition.live(configuration:config).test(.live) { http in
                try await RunHTTPTestSupport.wait {
                    (try? await publication.status(actorID:actor,runID:request.runID,deadline:.now.advanced(by:.seconds(4))))?.phase == .succeeded
                }
                let response = try await http.executeRequest(uri:"/api/v1/runs/"+request.runID.uuidString+"/events",method:.get,
                    headers:[.authorization:"Bearer "+String(repeating:"b",count:64)],body:nil)
                XCTAssertEqual(response.status,.ok)
                let frames = try RunHTTPTestSupport.frames(response.body)
                XCTAssertEqual(frames.count,6)
                let value = try XCTUnwrap(frames[1].1["value"] as? NSDictionary)
                XCTAssertEqual(value,try JSONSerialization.jsonObject(with:JSONEncoder().encode(answer)) as? NSDictionary)
            }
            // Stale old publication ownership cannot overwrite recovered output.
            do { _ = try await publication.finish(claim,outcome:.cancelled,at:clock.now(),deadline:.now.advanced(by:.seconds(4)));XCTFail("Old owner published") }
            catch { XCTAssertEqual(error as? RunEventStoreError,.conflict) }
            async let a = publication.recoverNextCompleted(at:clock.now(),deadline:.now.advanced(by:.seconds(4)))
            async let b = PostgresRunPublicationStore(client:second,actorID:actor).recoverNextCompleted(at:clock.now(),deadline:.now.advanced(by:.seconds(4)))
            let repeated = try await [a,b];XCTAssertEqual(repeated,[false,false])
            try await ServerComposition.live(configuration:config).test(.live) { _ in
                let status = try await publication.status(actorID:actor,runID:request.runID,deadline:.now.advanced(by:.seconds(4)))
                XCTAssertEqual(status.stream.nextSequence,7);XCTAssertEqual(status.phase,.succeeded)
            }
            }
        }
    }
    func testDurableTaskRoundTripConflictAndActorScope() async throws {
        try await RunHTTPTestSupport.withClients { client,second in
            let actor = UUID(),run = UUID(),trace = UUID(),requestID = UUID(),thread = UUID(),entity = UUID()
            let binding = AGUIRunBinding(actorID:actor,runID:run,threadID:thread,requestID:requestID)
            _ = try await PostgresRunEventStore(client:client,actorID:actor).create(binding,retentionSeconds:3600,deadline:.now.advanced(by:.seconds(4)))
            let options = try ReadPlanningOptions(preferredModelID:"local-fixture",maximumOutputTokens:64,
                deadline:UTCInstant(secondsSince1970:1_900_000_000.1234567))
            let request = try ReadRunRequest(actorID:actor,runID:run,traceID:trace,requestID:requestID,question:"private recovery question",
                planningScope:ReadPlanningScope(entities:[PlanningEntity(id:entity,label:"Private label")],maximumWindowSeconds:123.456789),
                effectiveToolScope:["world:read"],intent:.historical,modelOptions:options,budget:RunBudget(steps:9,calls:2,activeMilliseconds:12000))
            let task = StoredReadRunTask(request:request,threadID:thread)
            let store = PostgresReadRunTaskStore(client:client,actorID:actor)
            try await store.save(task,deadline:.now.advanced(by:.seconds(4)))
            try await store.save(task,deadline:.now.advanced(by:.seconds(4)))
            let loaded = try await PostgresReadRunTaskStore(client:second,actorID:actor).load(runID:run,deadline:.now.advanced(by:.seconds(4)))
            let saved = try XCTUnwrap(loaded)
            XCTAssertEqual(saved.threadID,thread);XCTAssertEqual(saved.request.traceID,trace)
            XCTAssertEqual(saved.request.question,request.question);XCTAssertEqual(saved.request.budget,request.budget)
            XCTAssertEqual(saved.request.modelOptions.deadline.secondsSince1970.bitPattern,options.deadline.secondsSince1970.bitPattern)
            XCTAssertEqual(saved.request.planningScope.maximumWindowSeconds.bitPattern,request.planningScope.maximumWindowSeconds.bitPattern)
            let foreign = try await PostgresReadRunTaskStore(client:second,actorID:UUID()).load(runID:run,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertNil(foreign)
            let changed = ReadRunRequest(actorID:actor,runID:run,traceID:trace,requestID:requestID,question:"changed",
                planningScope:request.planningScope,effectiveToolScope:request.effectiveToolScope,intent:request.intent,modelOptions:options,budget:request.budget)
            do { try await store.save(StoredReadRunTask(request:changed,threadID:thread),deadline:.now.advanced(by:.seconds(4)));XCTFail("Task was overwritten") }
            catch { XCTAssertEqual(error as? ReadRunTaskError,.conflict) }
            do { try await PostgresReadRunTaskStore(client:second,actorID:UUID()).save(task,deadline:.now.advanced(by:.seconds(4)));XCTFail("Foreign task accepted") }
            catch { XCTAssertEqual(error as? ReadRunTaskError,.invalidState) }
            do { _ = try await client.query("UPDATE read_run_tasks SET task='{}'::jsonb WHERE actor_id=\(actor) AND run_id=\(run)").collect();XCTFail("Task updated directly") }
            catch { XCTAssertTrue(error is PSQLError) }
        }
    }
    func testLiveWatchDispatcherRunsWithoutModelAndResumesAfterShutdown() async throws {
        try await RunHTTPTestSupport.withClients { client,_ in
            let actor = UUID(),entity = UUID()
            _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect()
            let config = try RunHTTPTestSupport.configuration(actor: actor,token: String(repeating: "a",count: 64))
            let store = PostgresIntentionStore(actorID: actor,client: client)
            let watch = try await store.watch(entityID: entity,key: "live",deadline: .now.advanced(by: .seconds(4)))
            let journal = PostgresWorldRepository(client: client)
            let input = try Self.report(actor: actor,entity: entity),movement = input.events[0]
            let epoch = try MovementEpoch(detector: ConfirmedMovementDetector(actorID: actor,entityID: entity,epochID: movement.epochID,entityType: movement.entityType,policy: movement.policy),samples: input.samples,origin: .synthetic)
            try await ServerComposition.live(configuration: config).test(.live) { _ in
                _ = try await MovementEpochRecovery(store: PostgresMovementEpochStore(client: client,actorID: actor),publisher: MovementPublisher(actorID: actor,repository: journal)).submit(epoch,deadline: .now.advanced(by: .seconds(4)))
                try await RunHTTPTestSupport.wait {
                    (try? await store.load(id: watch.id,deadline: .now.advanced(by: .seconds(4))))?.status == .fulfilled
                }
            }
            // A new application instance must drain any remaining source/notification
            // events without redelivering the fulfilled intention.
            try await ServerComposition.live(configuration: config).test(.live) { _ in
                try await RunHTTPTestSupport.wait {
                    let rows = try? await client.query("SELECT c.last_sequence=(SELECT max(sequence) FROM world_events WHERE actor_id=\(actor)) FROM watch_dispatch_cursors c WHERE actor_id=\(actor)").collect()
                    return (try? rows?.first?.decode(Bool.self)) == true
                }
                let page = try await journal.page(actorID: actor,afterSequence: 0,cursor: nil,limit: 20,deadline: .now.advanced(by: .seconds(4)))
                XCTAssertEqual(page.events.filter { $0.draft.type == "memory.watch_notified" }.count,1)
            }
        }
    }
    func testLiveCompositionOwnsReadPipelineAndReportsModelFreeLimitation() async throws {
        try await RunHTTPTestSupport.withClients { client,_ in
            let (fixture,model,_,source) = try await RunHTTPTestSupport.realHarness(client:client)
            let ownershipDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("squidra-live-owner-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:ownershipDirectory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let localOwner = try LocalRunOwnership.acquire(directory:ownershipDirectory,actorID:fixture.actor)
            defer { localOwner.releaseAfterJoiningWorkers();try? FileManager.default.removeItem(at:ownershipDirectory) }
            let recorder = PrivateTraceRecorder(limits:try TraceLimits())
            let host = try ReadHostConfiguration(models:[model],entities:[PlanningEntity(id:fixture.entity,label:"Allowed fixture entity")])
            try await ServerComposition.live(configuration:fixture.configuration,readHost:host,traceRecorder:recorder,localOwnership:localOwner).test(.live) { http in
                let capabilities = try await http.executeRequest(uri:"/api/v1/run-capabilities",method:.get,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                XCTAssertEqual(capabilities.status,.ok)
                XCTAssertEqual(try RunHTTPTestSupport.object(capabilities.body)["textRuns"] as? Bool,true)
                let accepted = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:RunHTTPTestSupport.body(fixture.entity))
                XCTAssertEqual(accepted.status,.accepted)
                let path = try XCTUnwrap(accepted.headers[.location])
                let acceptedFields = try RunHTTPTestSupport.object(accepted.body)
                let acceptedID = try XCTUnwrap((acceptedFields["runId"] as? String).flatMap(UUID.init(uuidString:)))
                let ownedRows = try await client.query("SELECT owner_id FROM read_run_owners WHERE actor_id=\(fixture.actor) AND run_id=\(acceptedID)").collect()
                XCTAssertEqual(try ownedRows.first?.decode(UUID.self),localOwner.ownerID)
                let savedTask = try await PostgresReadRunTaskStore(client:client,actorID:fixture.actor).load(runID:acceptedID,deadline:.now.advanced(by:.seconds(4)))
                XCTAssertEqual(savedTask?.request.question,"Read the fixture entity's historical evidence")
                XCTAssertEqual(savedTask?.request.planningScope.entities.map(\.id),[fixture.entity])
                XCTAssertEqual(savedTask?.request.effectiveToolScope,["world:read"])
                XCTAssertEqual(savedTask?.request.intent,.historical)

                _ = try await RunHTTPTestSupport.completed(http,token:fixture.token,path:path)
                let events = try await http.executeRequest(uri:path+"/events",method:.get,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                let frames = try RunHTTPTestSupport.frames(events.body)
                let answer = try XCTUnwrap(frames[1].1["value"] as? [String:Any])
                let archived = try await PostgresReadRunCompletionStore(client:client,actorID:fixture.actor).load(runID:acceptedID,deadline:.now.advanced(by:.seconds(4)))
                let completion = try XCTUnwrap(archived)
                XCTAssertEqual(try JSONSerialization.jsonObject(with:completion.answerJSON) as? NSDictionary,answer as NSDictionary)
                let runSnapshot = try await PostgresRunStore(client:client).load(actorID:fixture.actor,runID:acceptedID,deadline:.now.advanced(by:.seconds(4)))
                XCTAssertEqual(runSnapshot.state,.completed)
                XCTAssertLessThan(completion.respondingVersion,runSnapshot.version)
                let savedPlan = try await PostgresReadRunPlanStore(client:client,actorID:fixture.actor).load(runID:acceptedID,deadline:.now.advanced(by:.seconds(4)))
                let planArchive = try XCTUnwrap(savedPlan)
                XCTAssertEqual(planArchive.requestID,completion.requestID)
                XCTAssertLessThan(planArchive.planningVersion,completion.respondingVersion)
                let restored = try ReadPlanner(router:ModelRouter(models:[model],clock:RunHTTPTestSupport.clock),clock:RunHTTPTestSupport.clock)
                    .restore(planArchive.archive,scope:ReadPlanningScope(entities:[PlanningEntity(id:fixture.entity,label:"Allowed fixture entity")]),maximumCostMicroUSD:0,maximumOutputTokens:512)
                XCTAssertEqual(restored.proposal.target,"entity:"+fixture.entity.uuidString.lowercased())
                XCTAssertEqual(restored.routing.reservedCostUpperBoundMicroUSD,0)

                let storedTool = try await PostgresReadRunToolResultStore(client:client,actorID:fixture.actor).load(runID:acceptedID,deadline:.now.advanced(by:.seconds(4)))
                let toolArchive = try XCTUnwrap(storedTool)
                XCTAssertEqual(toolArchive.requestID,completion.requestID)
                XCTAssertLessThan(planArchive.planningVersion,toolArchive.executionVersion)
                XCTAssertLessThan(toolArchive.executionVersion,completion.respondingVersion)
                XCTAssertEqual(toolArchive.toolIdentifier,restored.proposal.tool.identifier)
                let command = try ActionCommand(actorID:fixture.actor,runID:acceptedID,tool:restored.proposal.tool,
                    idempotencyKey:"read:"+acceptedID.uuidString.lowercased(),target:restored.proposal.target,arguments:restored.proposal.arguments,scope:["world:read"])
                XCTAssertEqual(toolArchive.commandFingerprint,command.fingerprintHex)
                let catalog = try ToolCatalog(definitions:[WorldLocationTool.definition(),WorldChangesTool.definition()])
                let untrusted = try catalog.validateOutput(toolArchive.payload,for:restored.proposal.tool)
                let restoredEvidence = try WorldReadEvidenceDecoder().decode(untrusted,proposal:restored.proposal,actorID:fixture.actor,intent:.historical,
                    clock:RunHTTPTestSupport.clock,policy:AnswerFreshnessPolicy(maximumObservationAgeSeconds:60,minimumCurrentConfidence:Confidence(0.5)))
                XCTAssertFalse(restoredEvidence.entityNotFound)
                let savedAnswer = try await PostgresReadRunAnswerStore(client:client,actorID:fixture.actor).load(runID:acceptedID,deadline:.now.advanced(by:.seconds(4)))
                let answerArchive = try XCTUnwrap(savedAnswer),routing = try ReadAnswerArchive.decode(answerArchive.archive)
                XCTAssertEqual(answerArchive.requestID,completion.requestID)
                XCTAssertEqual(answerArchive.respondingVersion,completion.respondingVersion)
                XCTAssertEqual(routing.response.requestID,completion.requestID)
                XCTAssertEqual(routing.reservedCostUpperBoundMicroUSD,0)
                let regrounded = try GroundedAnswerValidator().validate(routing.response,expectedRequestID:completion.requestID,context:restoredEvidence.context)
                XCTAssertEqual(regrounded.actorId,fixture.actor);XCTAssertEqual(regrounded.claims.count,1)
                let foreignAnswer = try await PostgresReadRunAnswerStore(client:client,actorID:UUID()).load(runID:acceptedID,deadline:.now.advanced(by:.seconds(4)))
                XCTAssertNil(foreignAnswer)
                do {
                    _ = try await client.query("UPDATE read_run_answers SET archive=archive WHERE actor_id=\(fixture.actor) AND run_id=\(acceptedID)").collect()
                    XCTFail("Answer routing update succeeded")
                } catch { /* Immutable model archive is enforced by PostgreSQL. */ }

                let foreignTool = try await PostgresReadRunToolResultStore(client:client,actorID:UUID()).load(runID:acceptedID,deadline:.now.advanced(by:.seconds(4)))
                XCTAssertNil(foreignTool)
                do {
                    _ = try await client.query("UPDATE read_run_tool_results SET payload=payload WHERE actor_id=\(fixture.actor) AND run_id=\(acceptedID)").collect()
                    XCTFail("Tool archive update succeeded")
                } catch { /* Immutable archive is enforced by PostgreSQL. */ }

                let foreignCompletion = try await PostgresReadRunCompletionStore(client:client,actorID:UUID()).load(runID:acceptedID,deadline:.now.advanced(by:.seconds(4)))
                XCTAssertNil(foreignCompletion)

                let evidence = try XCTUnwrap(answer["evidence"] as? [[String:Any]])
                XCTAssertEqual((evidence.first?["id"] as? String).flatMap(UUID.init(uuidString:)),source)
                let traceResponse = try await http.executeRequest(uri:path+"/trace",method:.get,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                XCTAssertEqual(traceResponse.status,.ok)
                let trace = try RunHTTPTestSupport.object(traceResponse.body)
                XCTAssertEqual(trace["partial"] as? Bool,false)
                let spans = try XCTUnwrap(trace["spans"] as? [[String:Any]])
                let acceptance = try RunHTTPTestSupport.object(accepted.body)
                let traceID = try XCTUnwrap(acceptance["traceId"] as? String)
                let runID = try XCTUnwrap(acceptance["runId"] as? String)
                let requestID = try XCTUnwrap(acceptance["requestId"] as? String)
                XCTAssertEqual(spans.filter { $0["stage"] as? String == "model" }.count,2)
                XCTAssertEqual(spans.filter { $0["stage"] as? String == "tool" }.count,1)
                XCTAssertEqual(spans.filter { $0["stage"] as? String == "projection" }.count,1)
                let rootSpan = try XCTUnwrap(spans.first { $0["stage"] as? String == "run" })
                XCTAssertEqual(rootSpan["outcome"] as? String,"ok")
                for span in spans {
                    let attributes = try XCTUnwrap(span["attributes"] as? [String:String])
                    XCTAssertEqual(attributes["squidra.trace_id"],traceID)
                    XCTAssertEqual(attributes["squidra.run_id"],runID)
                    XCTAssertEqual(attributes["squidra.task_id"],requestID)
                }
                XCTAssertTrue(spans.contains { ($0["attributes"] as? [String:String])?["squidra.event_id"] == source.uuidString.lowercased() })
                let text = String(buffer:traceResponse.body)
                for canary in [fixture.token,"fixture:http-read-private-canary","Allowed fixture entity","Read the fixture entity"] { XCTAssertFalse(text.contains(canary)) }
                let unauthorized = try await http.executeRequest(uri:path+"/trace",method:.get,headers:[:],body:nil)
                XCTAssertEqual(unauthorized.status,.unauthorized)
                let foreignTrace = try await http.executeRequest(uri:path+"/trace",method:.get,headers:[.authorization:"Bearer "+fixture.token,.init("X-Actor-ID")!:UUID().uuidString],body:nil)
                XCTAssertEqual(foreignTrace.status,.forbidden)
                let absentTrace = try await http.executeRequest(uri:"/api/v1/runs/"+UUID().uuidString+"/trace",method:.get,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                XCTAssertEqual(absentTrace.status,.notFound)
                let denied = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:RunHTTPTestSupport.body(UUID()))
                XCTAssertEqual(denied.status,.forbidden)
            }
            XCTAssertFalse(localOwner.isHeld)
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
    func testLiveTraceCancellationEndsRootWithoutPublishingQuestionOrEvidence() async throws {
        try await RunHTTPTestSupport.withClients { client,_ in
            let (fixture,model,_,_) = try await RunHTTPTestSupport.realHarness(client:client,pauseOnModelCall:1)
            let recorder = PrivateTraceRecorder(limits:try TraceLimits())
            let host = try ReadHostConfiguration(models:[model],entities:[PlanningEntity(id:fixture.entity,label:"private-label-canary")])
            try await ServerComposition.live(configuration:fixture.configuration,readHost:host,traceRecorder:recorder).test(.live) { http in
                let accepted = try await http.executeRequest(uri:"/api/v1/runs",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:RunHTTPTestSupport.body(fixture.entity))
                let path = try XCTUnwrap(accepted.headers[.location])
                try await RunHTTPTestSupport.wait { await model.calls == 1 }
                let cancelled = try await http.executeRequest(uri:path+"/cancel",method:.post,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                XCTAssertEqual(cancelled.status,.accepted)
                try await RunHTTPTestSupport.wait { let snapshot = await recorder.snapshot();return snapshot.spans.contains { $0.stage == .run } }
                let snapshot = await recorder.snapshot()
                XCTAssertEqual(snapshot.activeTraces,0);XCTAssertEqual(snapshot.activeSpans,0)
                XCTAssertEqual(snapshot.spans.first { $0.stage == .run }?.outcome,"cancelled")
                XCTAssertEqual(snapshot.spans.first { $0.stage == .model }?.outcome,"cancelled")
                XCTAssertFalse(snapshot.spans.contains { $0.attributes["squidra.event_id"] != nil })
                let response = try await http.executeRequest(uri:path+"/trace",method:.get,headers:[.authorization:"Bearer "+fixture.token],body:nil)
                XCTAssertEqual(response.status,.ok)
                XCTAssertFalse(String(buffer:response.body).contains("private-label-canary"))
            }
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
                    _ = try await client.query("DELETE FROM run_events WHERE run_id=\(run) AND sequence=1").collect()
                    _ = try await client.query("UPDATE run_event_streams SET minimum_retained_sequence=2 WHERE run_id=\(run)").collect()
                    for cursor in [nil,frames[0].0] as [String?] {
                        var headers:HTTPFields = [.authorization:"Bearer "+fixture.token]
                        if let cursor { headers[.init("Last-Event-ID")!] = cursor }
                        let truncated = try await http.executeRequest(uri:eventPath,method:.get,headers:headers,body:nil)
                        XCTAssertEqual(truncated.status,.gone)
                        XCTAssertEqual(try RunHTTPTestSupport.object(truncated.body)["code"] as? String,"EXPIRED")
                        XCTAssertFalse(String(buffer:truncated.body).contains("RUN_ERROR"))
                    }
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
