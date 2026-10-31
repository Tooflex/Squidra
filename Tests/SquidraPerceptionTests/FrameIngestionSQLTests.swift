import Foundation
import Logging
import PostgresNIO
import SquidraAgentRuntime
import SquidraCognition
import SquidraDomain
import SquidraMeta
import SquidraPerception
import SquidraPostgres
import SquidraSecurity
import SquidraTemporal
import SquidraTools
import SquidraWorld
import XCTest

private actor FrameAnswerFixture: LanguageModel {
    nonisolated let descriptor = ModelDescriptor(id:"fixture.frame-answer",modelVersion:"1",location:.local,capabilities:[.text,.structuredOutput])
    let responses: [String]
    private(set) var calls = 0
    init(plan: String, answer: String) { responses = [plan,answer] }
    func generate(_ request: ModelRequest) throws -> ModelResponse {
        guard calls < responses.count else { throw ModelProviderError.unavailable }
        let text = responses[calls]; calls += 1
        return ModelResponse(requestID:request.id,modelID:descriptor.id,modelVersion:descriptor.modelVersion,text:text,outputTokens:128,costMicroUSD:0)
    }
}
private struct UnpublishableVision: VisionModel {
    let identity: VisionIdentity
    let count: Int
    let confidence: Confidence?
    init(count: Int = 1, confidence: Confidence? = nil, deployment: VisionDeployment = .synthetic) throws {
        identity = try VisionIdentity(modelID:"fixture.unpublishable",version:"1",deployment:deployment)
        self.count = count; self.confidence = confidence
    }
    func detect(_ request: VisionRequest) throws -> VisionOutput {
        var pixels = Data(repeating:0,count:64); pixels[0] = 1
        let detections = try (0..<count).map { index in
            try VisionDetection(localID:"object-\(index)",label:"untrusted label",box:PixelBox(x:0,y:0,width:1,height:1),
                mask:BinaryMask(width:8,height:8,pixels:pixels),confidence:confidence,appearance:nil)
        }
        return VisionOutput(identity:identity,context:request.context,imageSHA256:request.imageSHA256,detections:detections)
    }
}

// SAFETY: no shared mutable suite state; each scenario owns an actor/camera,
// and failure triggers are restricted to that actor in an isolated test DB.
final class FrameIngestionSQLTests: XCTestCase, @unchecked Sendable {
    private static var root: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private static func data() throws -> Data { try Data(contentsOf:root.appendingPathComponent("fixtures/providers/vision-synthetic.v1.json")) }
    private static func model() throws -> SyntheticVisionModel { try SyntheticVisionModel(fixtureData:data()) }
    private static func image(_ index: Int = 0) throws -> Data {
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with:data()) as? [String:Any])
        let frames = try XCTUnwrap(fixture["frames"] as? [[String:Any]])
        return try XCTUnwrap(Data(base64Encoded:XCTUnwrap(frames[index]["imageBase64"] as? String)))
    }
    private static func client() throws -> PostgresClient {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw WorldJournalError.unavailable }
        return try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
    }
    private static func withClients(_ body: @Sendable (PostgresClient,PostgresClient) async throws -> Void) async throws {
        let a = try client(), b = try client()
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await a.run() }; group.addTask { await b.run() }; defer { group.cancelAll() }
            try await body(a,b)
        }
    }
    private static func scene(_ client: PostgresClient) async throws -> SyntheticScenePolicy {
        let policy = try SyntheticScenePolicy(actorID:UUID(),cameraID:UUID(),locationID:UUID(),coordinateFrameID:UUID())
        _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(policy.locationID),\(policy.actorID),'fixture_scene')").collect()
        _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(policy.coordinateFrameID),\(policy.actorID),'host scene',3,'metres')").collect()
        return policy
    }
    private static func context(_ policy: SyntheticScenePolicy, index: Int = 0) throws -> FrameContext {
        try FrameContext(actorID:policy.actorID,cameraID:policy.cameraID,frameID:UUID(),
            timestamps:ObservationTimestamps(occurredAt:nil,observedAt:UTCInstant(secondsSince1970:1_700_000_000+Double(index)*2),
                recordedAt:UTCInstant(secondsSince1970:1_700_000_001+Double(index)*2),timeZone:IANATimeZone(identifier:"Europe/Paris")))
    }
    private static func consent(_ policy: SyntheticScenePolicy) -> FrameImportConsent {
        FrameImportConsent(actorID:policy.actorID,cameraID:policy.cameraID,permitsLocalProcessing:true,permitsCloudTransfer:false,expiresAt:.now.advanced(by:.seconds(120)))
    }
    private static func ingest(_ pipeline: PostgresFrameIngestion, _ context: FrameContext, index: Int = 0) async throws -> FrameIngestionReceipt {
        try await pipeline.ingest(bytes:image(index),mediaType:"image/png",context:context,consent:consent(pipeline.policy),deadline:.now.advanced(by:.seconds(15)))
    }
    private static func count(_ client: PostgresClient, actor: UUID) async throws -> Int64 {
        let rows = try await client.query("SELECT count(*)::bigint FROM world_events WHERE actor_id=\(actor)").collect()
        return try rows[0].decode(Int64.self)
    }
    func testPNGToPersistedInferenceToGroundedAnswerAndReplay() async throws {
        try await Self.withClients { client,second in
            let policy = try await Self.scene(client), context = try Self.context(policy)
            let pipeline = try PostgresFrameIngestion(client:client,model:Self.model(),policy:policy)
            let receipt = try await Self.ingest(pipeline,context)
            XCTAssertTrue(receipt.created); XCTAssertEqual(receipt.locations.count,2)
            XCTAssertEqual(receipt.observation.draft.id,context.frameID)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with:receipt.observation.draft.payload.bytes) as? [String:Any])
            XCTAssertEqual(payload["deployment"] as? String,"synthetic"); XCTAssertEqual(payload["modelId"] as? String,"fixture.vision")
            XCTAssertEqual(payload["modelVersion"] as? String,"1.0.0"); XCTAssertEqual(payload["imageSHA256"] as? String,receipt.resolution.imageSHA256)
            let encoded = String(decoding:receipt.observation.draft.payload.bytes,as:UTF8.self)
            for forbidden in ["imageBase64","mask","appearance"] { XCTAssertFalse(encoded.contains(forbidden)) }
            let projection = PostgresLocationProjection(actorID:policy.actorID,client:second)
            let event = try XCTUnwrap(receipt.locations.first), subject = try XCTUnwrap(receipt.resolution.assignments.first?.entityID)
            let validAt = try UTCInstant(secondsSince1970:context.timestamps.observedAt.secondsSince1970+0.5)
            let knownAt = try XCTUnwrap(receipt.locations.last?.recordedAt)
            let snapshot = try await projection.state(actorID:policy.actorID,subjectID:subject,validAt:validAt,knownAt:knownAt,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(snapshot.facts.count,1); XCTAssertEqual(snapshot.facts.first?.basis,.inferred)
            XCTAssertEqual(snapshot.facts.first?.sourceEventID,event.draft.id); XCTAssertNil(snapshot.facts.first?.timestamps.occurredAt)
            XCTAssertEqual(event.draft.causationID,receipt.observation.draft.id)
            XCTAssertEqual(snapshot.facts.first?.timestamps.timeZone.identifier,"Europe/Paris")
            let expired = try await projection.state(actorID:policy.actorID,subjectID:subject,
                validAt:UTCInstant(secondsSince1970:context.timestamps.observedAt.secondsSince1970+1),knownAt:knownAt,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertTrue(expired.facts.isEmpty)
            let replay = try await Self.ingest(PostgresFrameIngestion(client:second,model:Self.model(),policy:policy),context)
            XCTAssertFalse(replay.created); XCTAssertEqual(replay.resolution,receipt.resolution)
            XCTAssertEqual(replay.locations.map(\.draft.id),receipt.locations.map(\.draft.id))
            let total = try await Self.count(client,actor:policy.actorID); XCTAssertEqual(total,3)
            let clock = try SystemClock(timeZone:IANATimeZone(identifier:"Etc/UTC"))
            let plan: [String:Any] = ["schemaVersion":"1","tool":"world.get_entity_location@1.0.0","arguments":["schemaVersion":"1","entityId":subject.uuidString,
                "validAt":try RFC3339.format(validAt),"knownAt":try RFC3339.format(knownAt)]]
            let answer: [String:Any] = ["schemaVersion":"1","claims":[["kind":"location","subjectId":subject.uuidString,"locationId":policy.locationID.uuidString,
                "frameId":policy.coordinateFrameID.uuidString,"citations":[event.draft.id.uuidString]]]]
            let model = FrameAnswerFixture(plan:String(decoding:try JSONSerialization.data(withJSONObject:plan),as:UTF8.self),
                answer:String(decoding:try JSONSerialization.data(withJSONObject:answer),as:UTF8.self))
            let registration = try WorldLocationTool(world:projection).registration()
            let permission = HostActionPermission(actorID:policy.actorID,tool:registration.definition.id,capability:registration.definition.capability,
                targets:["entity:"+subject.uuidString.lowercased()],scope:["world:read"],expiresAt:.now.advanced(by:.seconds(60)))
            let engine = try ReadRunEngine(router:ModelRouter(models:[model],clock:clock),gateway:ActionGateway(tools:[registration],policy:HostActionPolicy(permissions:[permission])),
                store:PostgresRunStore(client:client),clock:clock,freshness:AnswerFreshnessPolicy(maximumObservationAgeSeconds:3600,minimumCurrentConfidence:Confidence(0.5)))
            let result = try await engine.execute(ReadRunRequest(actorID:policy.actorID,question:"What scene contained the authored object at that time?",
                planningScope:ReadPlanningScope(entities:[PlanningEntity(id:subject,label:"Fixture candidate")]),effectiveToolScope:["world:read"],intent:.historical,
                modelOptions:ReadPlanningOptions(deadline:UTCInstant(secondsSince1970:clock.now().secondsSince1970+30)),budget:RunBudget(steps:1,calls:1,repetitions:1)))
            XCTAssertEqual(result.snapshot.state,.completed); XCTAssertEqual(result.answer.claims.first?.basis,"inferred")
            XCTAssertEqual(result.answer.evidence.first?.id,event.draft.id); XCTAssertEqual(result.answer.evidence.first?.confidence,event.draft.confidence.value)
            XCTAssertEqual(result.answer.evidence.first?.source,"synthetic-frame:"+receipt.resolution.imageSHA256)
            let calls = await model.calls; XCTAssertEqual(calls,2)
            let next = try await Self.ingest(pipeline,Self.context(policy,index:1),index:1)
            XCTAssertEqual(next.resolution.assignments.map(\.entityID),receipt.resolution.assignments.map(\.entityID))
            XCTAssertEqual(next.resolution.assignments.map(\.kind),[.matched,.matched])
            do { _ = try await Self.ingest(pipeline,context); XCTFail("Old cache frame must not be silently re-associated") }
            catch { XCTAssertEqual(error as? EntityAssociationError,.outOfOrder) }
        }
    }
    func testAtomicJournalFailureThenStagedAssociationRetry() async throws {
        try await Self.withClients { client,_ in
            let policy = try await Self.scene(client), context = try Self.context(policy)
            let pipeline = try PostgresFrameIngestion(client:client,model:Self.model(),policy:policy)
            try await Self.reject(client,actor:policy.actorID,projection:false)
            do { _ = try await Self.ingest(pipeline,context); XCTFail("Injected batch failure accepted") } catch {}
            let failedCount = try await Self.count(client,actor:policy.actorID); XCTAssertEqual(failedCount,0)
            let store = PostgresEntityAssociationStore(client:client,actorID:policy.actorID,cameraID:policy.cameraID)
            let stagedValue = try await store.load(actorID:policy.actorID,cameraID:policy.cameraID,deadline:.now.advanced(by:.seconds(4)))
            let staged = try XCTUnwrap(stagedValue)
            try await Self.removeRejection(client,projection:false)
            let retried = try await Self.ingest(pipeline,context)
            XCTAssertTrue(retried.created); XCTAssertEqual(retried.resolution,staged.resolution)
            let total = try await Self.count(client,actor:policy.actorID); XCTAssertEqual(total,3)
            let changed = try SyntheticScenePolicy(actorID:policy.actorID,cameraID:policy.cameraID,locationID:policy.locationID,
                coordinateFrameID:policy.coordinateFrameID,validityMilliseconds:500)
            do { _ = try await Self.ingest(PostgresFrameIngestion(client:client,model:Self.model(),policy:changed),context); XCTFail("Changed scene policy replay accepted") }
            catch { XCTAssertEqual(error as? WorldJournalError,.idempotencyConflict) }
            let unchanged = try await Self.count(client,actor:policy.actorID); XCTAssertEqual(unchanged,3)
        }
    }
    func testCommittedJournalSurvivesProjectionFailureAndRebuilds() async throws {
        try await Self.withClients { client,second in
            let policy = try await Self.scene(client), context = try Self.context(policy)
            let pipeline = try PostgresFrameIngestion(client:client,model:Self.model(),policy:policy)
            try await Self.reject(client,actor:policy.actorID,projection:true)
            do { _ = try await Self.ingest(pipeline,context); XCTFail("Projection failure reported success") } catch {}
            let committed = try await Self.count(client,actor:policy.actorID); XCTAssertEqual(committed,3)
            try await Self.removeRejection(client,projection:true)
            let restored = try await Self.ingest(PostgresFrameIngestion(client:second,model:Self.model(),policy:policy),context)
            XCTAssertFalse(restored.created); XCTAssertEqual(restored.recovery.projectedThroughSequence,restored.locations.last?.sequence)
            _ = try await client.query("DELETE FROM spatial_facts WHERE actor_id=\(policy.actorID)").collect()
            _ = try await client.query("DELETE FROM projection_versions WHERE actor_id=\(policy.actorID)").collect()
            let rebuilt = try await Self.ingest(pipeline,context)
            XCTAssertFalse(rebuilt.created); XCTAssertEqual(rebuilt.locations.map(\.draft.id),restored.locations.map(\.draft.id))
            XCTAssertEqual(rebuilt.recovery.replayedEvents,3)
        }
    }
    func testScopeConsentUnknownConfidenceBoundsAndMissingFrameFailClosed() async throws {
        try await Self.withClients { client,_ in
            let policy = try await Self.scene(client), context = try Self.context(policy)
            XCTAssertThrowsError(try SyntheticScenePolicy(actorID:policy.actorID,cameraID:policy.cameraID,locationID:policy.locationID,
                coordinateFrameID:policy.coordinateFrameID,validityMilliseconds:1001))
            XCTAssertThrowsError(try PostgresFrameIngestion(client:client,model:UnpublishableVision(deployment:.local),policy:policy))
            for model in [try UnpublishableVision(),try UnpublishableVision(count:0),try UnpublishableVision(count:17,confidence:Confidence(0.8))] {
                do { _ = try await Self.ingest(PostgresFrameIngestion(client:client,model:model,policy:policy),context); XCTFail("Unsupported detection set published") }
                catch { XCTAssertEqual(error as? FramePublicationError,.invalidDetections) }
            }
            let pipeline = try PostgresFrameIngestion(client:client,model:Self.model(),policy:policy)
            for foreign in [FrameContext(actorID:UUID(),cameraID:policy.cameraID,frameID:context.frameID,timestamps:context.timestamps),
                            FrameContext(actorID:policy.actorID,cameraID:UUID(),frameID:context.frameID,timestamps:context.timestamps)] {
                do { _ = try await Self.ingest(pipeline,foreign); XCTFail("Foreign frame published") }
                catch { XCTAssertEqual(error as? FramePublicationError,.scopeMismatch) }
            }
            for consent in [FrameImportConsent(actorID:UUID(),cameraID:policy.cameraID,permitsLocalProcessing:true,permitsCloudTransfer:false,expiresAt:.now.advanced(by:.seconds(10))),
                FrameImportConsent(actorID:policy.actorID,cameraID:policy.cameraID,permitsLocalProcessing:false,permitsCloudTransfer:true,expiresAt:.now.advanced(by:.seconds(10))),
                FrameImportConsent(actorID:policy.actorID,cameraID:policy.cameraID,permitsLocalProcessing:true,permitsCloudTransfer:false,expiresAt:.now.advanced(by:.seconds(-1)))] {
                do { _ = try await pipeline.ingest(bytes:Self.image(),mediaType:"image/png",context:context,consent:consent,deadline:.now.advanced(by:.seconds(10))); XCTFail("Missing consent accepted") }
                catch { XCTAssertEqual(error as? FramePublicationError,.consentRequired) }
            }
            let staged = try await client.query("SELECT count(*)::bigint FROM entity_associations WHERE actor_id=\(policy.actorID)").collect()
            XCTAssertEqual(try staged[0].decode(Int64.self),0)
            let absent = try SyntheticScenePolicy(actorID:policy.actorID,cameraID:policy.cameraID,locationID:policy.locationID,coordinateFrameID:UUID())
            do { _ = try await Self.ingest(PostgresFrameIngestion(client:client,model:Self.model(),policy:absent),context); XCTFail("Unknown coordinate frame published") }
            catch { XCTAssertEqual(error as? WorldJournalError,.notFound) }
            let total = try await Self.count(client,actor:policy.actorID); XCTAssertEqual(total,0)
        }
    }
    func testCancellationDuringBlockedJournalRollsBackAndCanRetryStagedFrame() async throws {
        try await Self.withClients { client,second in
            let policy = try await Self.scene(client), context = try Self.context(policy)
            let pipeline = try PostgresFrameIngestion(client:client,model:Self.model(),policy:policy)
            try await second.withConnection(isolation:nil) { blocker in
                let logger = Logging.Logger(label:"fixture.frame-lock",factory:{ _ in Logging.SwiftLogNoOpLogHandler() })
                _ = try await blocker.query("BEGIN",logger:logger).collect()
                _ = try await blocker.query("SELECT pg_advisory_xact_lock(hashtextextended(\(policy.actorID.uuidString.lowercased()),1936818035))",logger:logger).collect()
                let pids = try await blocker.query("SELECT pg_backend_pid()",logger:logger).collect(), pid = try pids[0].decode(Int32.self)
                let worker = Task { try await Self.ingest(pipeline,context) }
                let end = ContinuousClock.now.advanced(by:.seconds(3)); var blocked: Int64 = 0
                repeat {
                    let rows = try await client.query("SELECT count(*)::bigint FROM pg_stat_activity WHERE \(pid)=ANY(pg_blocking_pids(pid))").collect()
                    blocked = try rows[0].decode(Int64.self)
                    if blocked > 0 { break }; try await Task.sleep(for:.milliseconds(5))
                } while ContinuousClock.now < end
                XCTAssertGreaterThan(blocked,0)
                worker.cancel()
                do { _ = try await worker.value; XCTFail("Cancelled blocked publication succeeded") } catch {}
                _ = try await blocker.query("ROLLBACK",logger:logger).collect()
            }
            let count = try await Self.count(client,actor:policy.actorID); XCTAssertEqual(count,0)
            let retry = try await Self.ingest(pipeline,context); XCTAssertTrue(retry.created)
            let final = try await Self.count(client,actor:policy.actorID); XCTAssertEqual(final,3)
        }
    }
    private static func reject(_ client: PostgresClient, actor: UUID, projection: Bool) async throws {
        let name = projection ? "reject_frame_projection" : "reject_frame_batch"
        let table = projection ? "spatial_facts" : "world_events"
        let condition = projection ? "true" : "NEW.event_type='world.location_asserted'"
        // UUID is host-generated; no request/model input enters this fixture DDL.
        _ = try await client.query(PostgresQuery(unsafeSQL:"CREATE FUNCTION \(name)() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.actor_id='\(actor)'::uuid AND \(condition) THEN RAISE EXCEPTION 'fixture rejection'; END IF; RETURN NEW; END $$")).collect()
        _ = try await client.query(PostgresQuery(unsafeSQL:"CREATE TRIGGER \(name) BEFORE INSERT ON \(table) FOR EACH ROW EXECUTE FUNCTION \(name)()")).collect()
    }
    private static func removeRejection(_ client: PostgresClient, projection: Bool) async throws {
        let name = projection ? "reject_frame_projection" : "reject_frame_batch", table = projection ? "spatial_facts" : "world_events"
        _ = try await client.query(PostgresQuery(unsafeSQL:"DROP TRIGGER \(name) ON \(table)")).collect()
        _ = try await client.query(PostgresQuery(unsafeSQL:"DROP FUNCTION \(name)()")).collect()
    }
}
