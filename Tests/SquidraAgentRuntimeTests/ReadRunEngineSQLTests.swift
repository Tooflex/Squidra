import Foundation
import PostgresNIO
import SquidraAgentRuntime
import SquidraCognition
import SquidraDomain
import SquidraPostgres
import SquidraSecurity
import SquidraTemporal
import SquidraTools
import SquidraWorld
import XCTest

private actor SQLRunModelFixture: LanguageModel {
    nonisolated let descriptor = ModelDescriptor(id:"fixture.sql-read-run",modelVersion:"1",location:.local,capabilities:[.text,.structuredOutput])
    let responses: [String]
    private var index = 0
    init(plan: String, answer: String) {
        responses = [plan,answer]
    }
    func generate(_ request: ModelRequest) throws -> ModelResponse {
        guard index < responses.count else { throw ModelProviderError.unavailable }
        let text = responses[index]; index += 1
        return ModelResponse(requestID:request.id,modelID:descriptor.id,modelVersion:descriptor.modelVersion,text:text,outputTokens:128,costMicroUSD:0)
    }
}
private actor SQLRunReadCounter: WorldStateQuery, WorldChangesQuerying {
    let projection: PostgresLocationProjection
    private(set) var calls = 0
    init(_ projection: PostgresLocationProjection) { self.projection = projection }
    func state(actorID: UUID, subjectID: UUID, validAt: UTCInstant, knownAt: UTCInstant, deadline: ContinuousClock.Instant) async throws -> WorldStateSnapshot {
        calls += 1
        return try await projection.state(actorID:actorID,subjectID:subjectID,validAt:validAt,knownAt:knownAt,deadline:deadline)
    }
    func changes(_ query: WorldChangesQuery, cursor: WorldChangesCursor?, limit: Int, deadline: ContinuousClock.Instant) async throws -> WorldChangesPage {
        calls += 1
        return try await projection.changes(query,cursor:cursor,limit:limit,deadline:deadline)
    }
}

// SAFETY: stateless suite; database/container is isolated, mutable spies are actors.
final class ReadRunEngineSQLTests: XCTestCase, @unchecked Sendable {
    private static func instant(_ micros: Int64) throws -> UTCInstant { try UTCInstant(secondsSince1970:Double(micros)/1_000_000) }
    func testRealDurableGroundedHistoricalUnknownAndPartialRuns() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["SQUIDRA_TEST_DB_PORT"], let port = Int(text), let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            XCTFail("Run through the isolated T14-SQL database helper"); return
        }
        let config = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra")
        let client = config.makeClient(), freshClient = config.makeClient()
        let actor = UUID(), subject = UUID(), missing = UUID(), a = UUID(), b = UUID(), d = UUID(), frame = UUID(), stream = UUID()
        let journal = PostgresWorldRepository(client:client), projection = PostgresLocationProjection(actorID:actor,client:client)
        let store = PostgresRunStore(client:client), reloadedStore = PostgresRunStore(client:freshClient), counter = SQLRunReadCounter(projection)
        let clock = try SystemClock(timeZone:IANATimeZone(identifier:"Etc/UTC"))
        let t0: Int64 = 1_700_000_000_000_000, t1 = t0+100_123_457, t2 = t0+200_000_000
        @Sendable func append(_ change: LocationFactChange, version: Int64, extra: [UUID] = []) async throws -> JournalEvent {
            let draft = try WorldEventDraft(actorID:actor,streamID:stream,entityIDs:[subject,change.locationID]+extra,type:change.eventType,
                times:JournalTimes(occurredAt:nil,observedAt:Self.instant(t0),timeZone:IANATimeZone(identifier:"Europe/Paris")),
                sourceID:"fixture:sql-grounded-run",confidence:Confidence(0.85),payloadVersion:1,payload:change.encodedPayload(),
                causationID:change.correctsEventID,correlationID:UUID())
            return try await journal.append(draft,expectedVersion:version,idempotencyKey:"sql-run-\(version)",deadline:.now.advanced(by:.seconds(4))).event
        }
        @Sendable func execute(entity: UUID, args: [String:Any], claim: [String:Any], changes: Bool = false) async throws -> ReadRunResult {
            let tool = changes ? "world.get_changes@1.0.0" : "world.get_entity_location@1.0.0"
            let plan = String(decoding:try JSONSerialization.data(withJSONObject:["schemaVersion":"1","tool":tool,"arguments":args]),as:UTF8.self)
            let answer = String(decoding:try JSONSerialization.data(withJSONObject:["schemaVersion":"1","claims":[claim]]),as:UTF8.self)
            let model = SQLRunModelFixture(plan:plan,answer:answer)
            let registrations = try [WorldLocationTool(world:counter).registration(),WorldChangesTool(world:counter).registration()]
            let permissions = registrations.map { HostActionPermission(actorID:actor,tool:$0.definition.id,capability:$0.definition.capability,
                targets:["entity:"+entity.uuidString.lowercased()],scope:["world:read"],expiresAt:.now.advanced(by:.seconds(60))) }
            let engine = try ReadRunEngine(router:ModelRouter(models:[model],clock:clock),gateway:ActionGateway(tools:registrations,policy:HostActionPolicy(permissions:permissions)),
                store:store,clock:clock,freshness:AnswerFreshnessPolicy(maximumObservationAgeSeconds:3600,minimumCurrentConfidence:Confidence(0.5)))
            let request = try ReadRunRequest(actorID:actor,question:"Read the fixture's historical evidence",planningScope:ReadPlanningScope(entities:[PlanningEntity(id:entity,label:"Fixture entity")]),
                effectiveToolScope:["world:read"],intent:.historical,modelOptions:ReadPlanningOptions(deadline:UTCInstant(secondsSince1970:clock.now().secondsSince1970+30)),
                budget:RunBudget(steps:1,calls:1,repetitions:1))
            let result = try await engine.execute(request)
            let loaded = try await reloadedStore.load(actorID:actor,runID:request.runID,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(loaded,result.snapshot); XCTAssertEqual(loaded.state,.completed)
            XCTAssertEqual(loaded.steps,1); XCTAssertEqual(loaded.calls,1)
            return result
        }
        @Sendable func locationArgs(entity: UUID, known: Int64) throws -> [String:Any] {
            ["schemaVersion":"1","entityId":entity.uuidString,"validAt":try RFC3339.format(Self.instant(t0+1_000_000)),"knownAt":try RFC3339.format(Self.instant(known))]
        }
        @Sendable func locationClaim(place: UUID, event: UUID) -> [String:Any] {
            ["kind":"location","subjectId":subject.uuidString,"locationId":place.uuidString,"frameId":frame.uuidString,"citations":[event.uuidString]]
        }
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() }; group.addTask { await freshClient.run() }; defer { group.cancelAll() }
            for entity in [subject,missing,a,b,d] { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect() }
            _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(frame),\(actor),'read-run',3,'metres')").collect()
            let first = try await append(LocationFactChange(subjectID:subject,locationID:a,frameID:frame,valid:FactInterval(fromMicroseconds:t0,toMicroseconds:t1),basis:.observed),version:0)
            let second = try await append(LocationFactChange(subjectID:subject,locationID:b,frameID:frame,valid:FactInterval(fromMicroseconds:t1,toMicroseconds:nil),basis:.observed),version:1)
            let correction = try await append(LocationFactChange(subjectID:subject,locationID:d,frameID:frame,valid:FactInterval(fromMicroseconds:t0,toMicroseconds:t1),basis:.observed,correctsEventID:first.draft.id),version:2,extra:[a])
            for event in [first,second,correction] { try await projection.apply(event) }
            let known = correction.recordedMicroseconds
            let corrected = try await execute(entity:subject,args:locationArgs(entity:subject,known:known),claim:locationClaim(place:d,event:correction.draft.id))
            XCTAssertEqual(corrected.answer.status,.grounded)
            XCTAssertEqual(corrected.answer.evidence.first?.id,correction.draft.id)
            XCTAssertEqual(corrected.answer.evidence.first?.confidence,0.85)
            XCTAssertEqual(corrected.answer.evidence.first?.timeZone,"Europe/Paris")
            XCTAssertNil(corrected.answer.evidence.first?.occurredAt)
            XCTAssertTrue(corrected.answer.uncertainty.contains("stale_observation"))
            let historical = try await execute(entity:subject,args:locationArgs(entity:subject,known:second.recordedMicroseconds),claim:locationClaim(place:a,event:first.draft.id))
            XCTAssertEqual(historical.answer.claims.first?.locationId,a)
            let unknown = try await execute(entity:missing,args:locationArgs(entity:missing,known:known),claim:["kind":"unknown","subjectId":missing.uuidString,"citations":[]])
            XCTAssertEqual(unknown.answer.status,.unknown); XCTAssertTrue(unknown.answer.evidence.isEmpty)
            let changes: [String:Any] = ["schemaVersion":"1","subjectId":subject.uuidString,"from":try RFC3339.format(Self.instant(t0)),
                "to":try RFC3339.format(Self.instant(t2)),"knownAt":try RFC3339.format(Self.instant(known)),"limit":1]
            let partial = try await execute(entity:subject,args:changes,claim:["kind":"change","subjectId":subject.uuidString,
                "changeId":correction.draft.id.uuidString,"citations":[first.draft.id.uuidString,correction.draft.id.uuidString]],changes:true)
            XCTAssertEqual(partial.answer.status,.partial); XCTAssertTrue(partial.answer.uncertainty.contains("partial_page"))
            XCTAssertEqual(Set(partial.answer.evidence.map(\.id)),[first.draft.id,correction.draft.id])
            let before = await counter.calls
            _ = try await client.query("""
                CREATE FUNCTION fixture_reject_read_dispatch() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN IF NEW.tool_call_count > OLD.tool_call_count THEN
                    RAISE EXCEPTION 'fixture rejected dispatch checkpoint' USING ERRCODE='23514';
                END IF; RETURN NEW; END $$
                """).collect()
            _ = try await client.query("CREATE TRIGGER fixture_reject_read_dispatch BEFORE UPDATE ON agent_runs FOR EACH ROW EXECUTE FUNCTION fixture_reject_read_dispatch()").collect()
            do {
                _ = try await execute(entity:subject,args:locationArgs(entity:subject,known:known),claim:locationClaim(place:d,event:correction.draft.id))
                XCTFail("Rejected reservation granted dispatch")
            } catch let failure as ReadRunFailure {
                XCTAssertEqual(failure.code,.recoveryRequired); XCTAssertNil(failure.state)
                let saved = try await reloadedStore.load(actorID:actor,runID:failure.runID,deadline:.now.advanced(by:.seconds(4)))
                XCTAssertEqual(saved.state,.executingTool); XCTAssertEqual(saved.calls,0)
            }
            let after = await counter.calls; XCTAssertEqual(after,before)
            _ = try await client.query("DROP TRIGGER fixture_reject_read_dispatch ON agent_runs").collect()
            _ = try await client.query("DROP FUNCTION fixture_reject_read_dispatch()").collect()
            do { _ = try await reloadedStore.load(actorID:UUID(),runID:corrected.snapshot.id,deadline:.now.advanced(by:.seconds(4))); XCTFail("Foreign run loaded") }
            catch { XCTAssertEqual(error as? RunStoreError,.notFound) }
        }
    }
}
