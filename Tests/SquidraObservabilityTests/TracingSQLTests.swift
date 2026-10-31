import Foundation
import PostgresNIO
import SquidraCognition
import SquidraDomain
import SquidraObservability
import SquidraPostgres
import SquidraSecurity
import SquidraTools
import SquidraWorld
import XCTest

private actor SQLTraceQueryCounter: WorldStateQuery {
    let projection: PostgresLocationProjection
    private(set) var calls = 0
    init(_ projection: PostgresLocationProjection) { self.projection = projection }
    func state(actorID: UUID, subjectID: UUID, validAt: UTCInstant, knownAt: UTCInstant, deadline: ContinuousClock.Instant) async throws -> WorldStateSnapshot {
        calls += 1
        return try await projection.state(actorID:actorID,subjectID:subjectID,validAt:validAt,knownAt:knownAt,deadline:deadline)
    }
}
private struct SQLTraceLanguageFixture: LanguageModel {
    let descriptor = ModelDescriptor(id:"fixture.sql-trace",modelVersion:"1",location:.local,capabilities:[.text],maximumCostMicroUSD:10)
    func generate(_ request: ModelRequest) throws -> ModelResponse {
        ModelResponse(schemaVersion:"1",requestID:request.id,modelID:descriptor.id,modelVersion:descriptor.modelVersion,
            text:"SECRET_fixture_model_response",outputTokens:3,costMicroUSD:2)
    }
}

// SAFETY: stateless suite; mutable query observations are actor-isolated and all
// SQL effects live in the helper's disposable loopback-only database.
final class TracingSQLTests: XCTestCase, @unchecked Sendable {
    func testActualModelGatewayJournalAndProjectionSharePrivateSourceTrace() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["SQUIDRA_TEST_DB_PORT"],let port = Int(text),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            XCTFail("Run through isolated SQD-030-SQL helper");return
        }
        let client = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
        let actor = UUID(),subject = UUID(),place = UUID(),frame = UUID(),stream = UUID()
        let correlation = try TraceCorrelation(runID:UUID(),taskID:UUID()),recorder = try PrivateTraceRecorder(limits:TraceLimits())
        let concrete = PostgresLocationProjection(actorID:actor,client:client),query = SQLTraceQueryCounter(concrete)
        let journal = TracedWorldRepository(PostgresWorldRepository(client:client)),projection = TracedWorldProjector(concrete)
        let original = try WorldLocationTool(world:query).registration()
        let wrapped = original.decoratingExecutor { TracedToolExecutor($0) }
        XCTAssertEqual(wrapped.definition,original.definition)
        if case .bounded = wrapped.surface {} else { XCTFail("Decoration changed tool surface") }
        let target = "entity:"+subject.uuidString.lowercased()
        let policy = HostActionPolicy(permissions:[HostActionPermission(actorID:actor,tool:original.definition.id,capability:original.definition.capability,targets:[target],scope:["world:read"],expiresAt:.now.advanced(by:.seconds(30)))])
        let gateway = try ActionGateway(tools:[wrapped],policy:policy)
        let router = try ModelRouter(models:[TracedLanguageModel(SQLTraceLanguageFixture())],clock:FixedClock(instant:UTCInstant(secondsSince1970:1_700_000_000),timeZone:IANATimeZone(identifier:"UTC")))
        let change = try LocationFactChange(subjectID:subject,locationID:place,frameID:frame,valid:FactInterval(fromMicroseconds:1_700_000_000_000_000,toMicroseconds:nil),basis:.observed)
        let draft = try WorldEventDraft(actorID:actor,streamID:stream,entityIDs:[subject,place],type:change.eventType,
            times:JournalTimes(occurredAt:nil,observedAt:UTCInstant(secondsSince1970:1_700_000_000.125),timeZone:IANATimeZone(identifier:"Europe/Paris")),
            sourceID:"SECRET_source_label",confidence:Confidence(0.8125),payloadVersion:1,payload:change.encodedPayload(),correlationID:correlation.traceID)
        @Sendable func arguments(knownAt: UTCInstant, entity: UUID = subject, extra: Bool = false) throws -> Data {
            var value:[String:Any] = ["schemaVersion":"1","entityId":entity.uuidString.lowercased(),"validAt":"2023-11-14T22:13:21Z","knownAt":try RFC3339.format(knownAt)]
            if extra { value["private"] = "SECRET_rejected_property" }
            return try JSONSerialization.data(withJSONObject:value)
        }
        @Sendable func action(_ input: Data, owner: UUID = actor, actionTarget: String = target) -> GatewayAction {
            GatewayAction(actorID:owner,runID:correlation.runID,tool:wrapped.definition.id,target:actionTarget,arguments:input,
                scope:["world:read"],idempotencyKey:"SECRET_read_key",deadline:.now.advanced(by:.seconds(4)))
        }
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            for id in [subject,place] { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind,label) VALUES(\(id),\(actor),'fixture','SECRET_entity_label')").collect() }
            _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(frame),\(actor),'SECRET_frame_name',3,'metres')").collect()
            let result = try await recorder.withTrace(correlation) { _ -> (Data,JournalEvent) in
                let request = try ModelRequest(id:UUID(),messages:[ModelMessage(role:.user,content:"SECRET_question_prompt")],maximumCostMicroUSD:10,maximumOutputTokens:16,deadline:UTCInstant(secondsSince1970:1_700_000_010))
                _ = try await router.generate(request)
                let append = try await journal.append(draft,expectedVersion:0,idempotencyKey:"SECRET_journal_key",deadline:.now.advanced(by:.seconds(4)))
                try await projection.apply(append.event)
                _ = try await projection.checkpoint()
                let output = try await gateway.invoke(action(arguments(knownAt:append.event.recordedAt)))
                guard case .completed(let untrusted) = output else { throw ToolError.invalidOutput }
                _ = try await router.generate(request)
                return (untrusted.payload,append.event)
            }
            let output = try XCTUnwrap(JSONSerialization.jsonObject(with:result.0) as? [String:Any])
            let facts = try XCTUnwrap(output["facts"] as? [[String:Any]]),fact = try XCTUnwrap(facts.first)
            XCTAssertEqual(facts.count,1);XCTAssertEqual(fact["sourceEventId"] as? String,result.1.draft.id.uuidString.lowercased())
            XCTAssertEqual(fact["confidence"] as? Double,0.8125);XCTAssertEqual(fact["timeZone"] as? String,"Europe/Paris")
            XCTAssertTrue(fact["occurredAt"] is NSNull);XCTAssertEqual(fact["source"] as? String,"SECRET_source_label")
            let snapshot = await recorder.snapshot()
            XCTAssertEqual(snapshot.spans.count,7);XCTAssertEqual(snapshot.droppedSpans,0);XCTAssertEqual(snapshot.activeSpans,0)
            XCTAssertEqual(snapshot.spans.filter { $0.stage == .model }.count,2)
            let references = snapshot.spans.filter { $0.attributes["squidra.event_id"] == result.1.draft.id.uuidString.lowercased() }
            XCTAssertEqual(references.count,2);XCTAssertEqual(Set(references.map(\.stage)),[.journal,.projection])
            XCTAssertTrue(references.allSatisfy { $0.attributes["squidra.world_sequence"] == String(result.1.sequence) })
            for span in snapshot.spans {
                XCTAssertEqual(span.traceID,correlation.traceID.uuidString.replacingOccurrences(of:"-",with:"").lowercased())
                XCTAssertEqual(span.attributes["squidra.run_id"],correlation.runID.uuidString.lowercased())
                XCTAssertEqual(span.attributes["squidra.task_id"],correlation.taskID?.uuidString.lowercased())
            }
            XCTAssertFalse(String(decoding:try JSONEncoder().encode(snapshot),as:UTF8.self).contains("SECRET_"))
            let before = await query.calls;XCTAssertEqual(before,1)
            // The original private target resolver survives executor wrapping.
            // Neither target mismatch can dispatch the SQL query adapter.
            for candidate in [try action(arguments(knownAt:result.1.recordedAt,entity:UUID())),try action(arguments(knownAt:result.1.recordedAt),actionTarget:"entity:"+UUID().uuidString.lowercased()),try action(arguments(knownAt:result.1.recordedAt),owner:UUID())] {
                do { _ = try await gateway.invoke(candidate);XCTFail("Foreign scope passed decoration") }
                catch { XCTAssertEqual(error as? ActionGatewayError,.denied) }
            }
            do { _ = try await gateway.invoke(action(arguments(knownAt:result.1.recordedAt,extra:true)));XCTFail("Schema validation disappeared") }
            catch { XCTAssertEqual(error as? ToolError,.invalidInput) }
            let denied = try ActionGateway(tools:[wrapped],policy:DenyAllActionPolicy())
            do { _ = try await denied.invoke(action(arguments(knownAt:result.1.recordedAt)));XCTFail("Policy validation disappeared") }
            catch { XCTAssertEqual(error as? ActionGatewayError,.denied) }
            let after = await query.calls;XCTAssertEqual(after,before)
        }
    }
}
