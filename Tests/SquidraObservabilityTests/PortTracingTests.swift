import Foundation
import SquidraCognition
import SquidraDomain
import SquidraObservability
import SquidraSecurity
import SquidraTools
import SquidraWorld
import XCTest

private actor TraceModelFixture: LanguageModel {
    enum Mode: Sendable { case normal, malformed, failed, slow }
    nonisolated let descriptor = ModelDescriptor(id:"fixture.trace-model",modelVersion:"1",location:.local,capabilities:[.text],maximumCostMicroUSD:10)
    let mode: Mode
    private(set) var calls = 0
    private(set) var lastRequestID: UUID?
    private(set) var cancelled = false
    init(_ mode: Mode = .normal) { self.mode = mode }
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        calls += 1;lastRequestID = request.id
        if mode == .failed { throw NSError(domain:"SECRET_provider_error",code:1) }
        if mode == .slow {
            do { try await ContinuousClock().sleep(for:.seconds(30)) } catch { cancelled = true;throw error }
        }
        return ModelResponse(schemaVersion:"1",requestID:mode == .malformed ? UUID() : request.id,
            modelID:descriptor.id,modelVersion:descriptor.modelVersion,text:"SECRET_model_output",outputTokens:5,costMicroUSD:3)
    }
}
private actor TraceToolFixture: ToolExecutor {
    let malformed: Bool
    private(set) var calls = 0
    private(set) var lastRunID: UUID?
    init(malformed: Bool = false) { self.malformed = malformed }
    func execute(_ call: ToolCall) throws -> Data {
        calls += 1;lastRunID = call.runID
        if malformed { return Data(#"{"private":"SECRET_bad_output"}"#.utf8) }
        let input = try JSONSerialization.jsonObject(with:call.input) as! [String:Any]
        return try JSONSerialization.data(withJSONObject:["schemaVersion":"1","entityId":input["entityId"]!,"message":"SECRET_tool_output"])
    }
}
private actor TraceWorldFixture: WorldRepository, WorldProjector {
    let fail: Bool
    private(set) var appendCalls = 0, pageCalls = 0, applyCalls = 0, checkpointCalls = 0
    private(set) var lastKey: String?
    private var event: JournalEvent?
    init(fail: Bool = false) { self.fail = fail }
    func append(_ draft: WorldEventDraft, expectedVersion: Int64, idempotencyKey: String, deadline: ContinuousClock.Instant) throws -> JournalAppend {
        appendCalls += 1;lastKey = idempotencyKey
        if fail { throw NSError(domain:"SECRET_journal_error",code:1) }
        let value = try JournalEvent(sequence:17,streamVersion:expectedVersion+1,draft:draft,recordedMicroseconds:1_700_000_001_500_000)
        event = value;return JournalAppend(event:value,created:true)
    }
    func page(actorID: UUID, afterSequence: Int64, cursor: JournalCursor?, limit: Int, deadline: ContinuousClock.Instant) throws -> JournalPage {
        pageCalls += 1
        return JournalPage(events:event.map { [$0] } ?? [],next:nil,throughSequence:event?.sequence ?? 0)
    }
    func apply(_ event: JournalEvent) throws { applyCalls += 1;self.event = event }
    func checkpoint() throws -> ProjectionCheckpoint {
        checkpointCalls += 1
        return try ProjectionCheckpoint(projectionVersion:1,lastSequence:event?.sequence,state:JSONDocument(Data(#"{"source":"SECRET_checkpoint_payload"}"#.utf8)))
    }
}

// SAFETY: stateless suite; mutable underlying observations are actor-isolated.
final class PortTracingTests: XCTestCase, @unchecked Sendable {
    private static func recorder() throws -> PrivateTraceRecorder { try PrivateTraceRecorder(limits:TraceLimits()) }
    private static func router(_ model: TraceModelFixture) throws -> ModelRouter {
        try ModelRouter(models:[TracedLanguageModel(model)],clock:FixedClock(instant:UTCInstant(secondsSince1970:1_700_000_000),timeZone:IANATimeZone(identifier:"UTC")))
    }
    private static func request() throws -> ModelRequest {
        try ModelRequest(id:UUID(),messages:[ModelMessage(role:.user,content:"SECRET_prompt")],maximumCostMicroUSD:10,maximumOutputTokens:10,deadline:UTCInstant(secondsSince1970:1_700_000_010))
    }
    private static func gateway(_ spy: TraceToolFixture, actor: UUID, run: UUID, deny: Bool = false) throws -> (ActionGateway,GatewayAction) {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let definition = try ToolDefinition(id:ToolID(namespace:"fixture",name:"echo",version:"1.0.0"),capability:"fixture.read",risk:.r0,idempotency:.readOnly,timeoutMilliseconds:1000,
            inputSchema:Data(contentsOf:root.appendingPathComponent("Schemas/tools/fixture.echo.1.0.0.input.json")),outputSchema:Data(contentsOf:root.appendingPathComponent("Schemas/tools/fixture.echo.1.0.0.output.json")))
        let entity = UUID().uuidString.lowercased(),target = "entity:"+entity
        let registration = GatewayToolRegistration(definition:definition,surface:.bounded,executor:TracedToolExecutor(spy),resolveTarget: { data in
            let value = try JSONSerialization.jsonObject(with:data) as! [String:Any]
            return "entity:"+(value["entityId"] as! String)
        })
        let policy = HostActionPolicy(permissions:[HostActionPermission(actorID:actor,tool:definition.id,capability:definition.capability,targets:[target],scope:["fixture:read"],expiresAt:.now.advanced(by:.seconds(20)))])
        let gateway = try ActionGateway(tools:[registration],policy:deny ? DenyAllActionPolicy() : policy)
        let input = try JSONSerialization.data(withJSONObject:["schemaVersion":"1","entityId":entity,"at":"2026-10-31T12:00:00Z","message":"SECRET_tool_input","limit":1])
        return (gateway,GatewayAction(actorID:actor,runID:run,tool:definition.id,target:target,arguments:input,scope:["fixture:read"],idempotencyKey:"SECRET_idempotency_key",deadline:.now.advanced(by:.seconds(3))))
    }
    private static func draft(correlation: UUID) throws -> WorldEventDraft {
        try WorldEventDraft(actorID:UUID(),streamID:UUID(),entityIDs:[UUID()],type:"fixture.trace",times:JournalTimes(occurredAt:nil,observedAt:UTCInstant(secondsSince1970:1_700_000_000.125),timeZone:IANATimeZone(identifier:"Europe/Paris")),sourceID:"SECRET_source_label",confidence:Confidence(0.75),payloadVersion:1,payload:Data(#"{"private":"SECRET_journal_payload"}"#.utf8),correlationID:correlation)
    }
    private static func assertPrivate(_ snapshot: TraceSnapshot) throws {
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(snapshot),as:UTF8.self).contains("SECRET_"))
        XCTAssertEqual(snapshot.activeSpans,0);XCTAssertEqual(snapshot.activeTraces,0)
    }
    func testActualRouterChildTaskRetainsSessionAndValidatedProviderUsage() async throws {
        let recorder = try Self.recorder(),correlation = try TraceCorrelation(runID:UUID()),model = TraceModelFixture(),request = try Self.request(),router = try Self.router(model)
        let result = try await recorder.withTrace(correlation) { session in try await session.withSpan(.planning) { try await router.generate(request) } }
        XCTAssertEqual(result.response.text,"SECRET_model_output")
        let calls = await model.calls,lastID = await model.lastRequestID;XCTAssertEqual(calls,1);XCTAssertEqual(lastID,request.id)
        let snapshot = await recorder.snapshot(),span = try XCTUnwrap(snapshot.spans.first { $0.stage == .model })
        XCTAssertEqual(snapshot.spans.count,3);XCTAssertEqual(span.attributes["squidra.request_id"],request.id.uuidString.lowercased())
        XCTAssertEqual(span.attributes["squidra.output_tokens"],"5");XCTAssertEqual(span.attributes["squidra.cost_micro_usd"],"3")
        XCTAssertEqual(span.parentSpanID,snapshot.spans.first { $0.stage == .planning }?.spanID)
        try Self.assertPrivate(snapshot)
    }
    func testConcurrentActualRouterCallsKeepRequestAndRunCorrelationSeparate() async throws {
        let recorder = try Self.recorder(),model = TraceModelFixture(),router = try Self.router(model)
        let a = try TraceCorrelation(runID:UUID()),b = try TraceCorrelation(runID:UUID()),requestA = try Self.request(),requestB = try Self.request()
        async let first = recorder.withTrace(a) { _ in try await router.generate(requestA) }
        async let second = recorder.withTrace(b) { _ in try await router.generate(requestB) }
        _ = try await (first,second)
        let snapshot = await recorder.snapshot();XCTAssertEqual(snapshot.spans.count,4)
        for (correlation,request) in [(a,requestA),(b,requestB)] {
            let spans = snapshot.spans.filter { $0.attributes["squidra.run_id"] == correlation.runID.uuidString.lowercased() }
            XCTAssertEqual(spans.count,2)
            let root = try XCTUnwrap(spans.first { $0.stage == .run }),model = try XCTUnwrap(spans.first { $0.stage == .model })
            XCTAssertEqual(model.parentSpanID,root.spanID)
            XCTAssertEqual(model.attributes["squidra.request_id"],request.id.uuidString.lowercased())
        }
        XCTAssertNil(TraceSession.current);try Self.assertPrivate(snapshot)
    }
    func testMalformedProviderResponseAndFailureRemainRouterDecisions() async throws {
        for mode in [TraceModelFixture.Mode.malformed,.failed] {
            let recorder = try Self.recorder(),model = TraceModelFixture(mode),router = try Self.router(model),request = try Self.request(),correlation = try TraceCorrelation(runID:UUID())
            do { _ = try await recorder.withTrace(correlation) { _ in try await router.generate(request) };XCTFail("Router accepted invalid provider") }
            catch { XCTAssertEqual(error as? ModelRoutingError,mode == .malformed ? .invalidResponse : .providerFailure) }
            let snapshot = await recorder.snapshot(),span = try XCTUnwrap(snapshot.spans.first { $0.stage == .model })
            XCTAssertNil(span.attributes["squidra.output_tokens"]);XCTAssertNil(span.attributes["squidra.cost_micro_usd"])
            try Self.assertPrivate(snapshot)
        }
    }
    func testActualGatewayRetainsGrantValidationAndTreatsOutputAsUntrusted() async throws {
        let recorder = try Self.recorder(),correlation = try TraceCorrelation(runID:UUID()),spy = TraceToolFixture()
        let (gateway,action) = try Self.gateway(spy,actor:UUID(),run:correlation.runID)
        let result = try await recorder.withTrace(correlation) { _ in try await gateway.invoke(action) }
        guard case .completed(let output) = result else { return XCTFail("No untrusted output") }
        XCTAssertTrue(String(decoding:output.payload,as:UTF8.self).contains("SECRET_tool_output"))
        let calls = await spy.calls,lastRun = await spy.lastRunID;XCTAssertEqual(calls,1);XCTAssertEqual(lastRun,correlation.runID)
        let snapshot = await recorder.snapshot();XCTAssertEqual(snapshot.spans.filter { $0.stage == .tool }.count,1);try Self.assertPrivate(snapshot)
        let denied = TraceToolFixture(),(blocked,blockedAction) = try Self.gateway(denied,actor:UUID(),run:correlation.runID,deny:true)
        do { _ = try await recorder.withTrace(try TraceCorrelation(runID:correlation.runID)) { _ in try await blocked.invoke(blockedAction) };XCTFail("Tracing bypassed denial") }
        catch { XCTAssertEqual(error as? ActionGatewayError,.denied) }
        let deniedCalls = await denied.calls;XCTAssertEqual(deniedCalls,0)
    }
    func testWrongToolRunDropsTraceAndMalformedOutputStillFailsCatalog() async throws {
        let recorder = try Self.recorder(),correlation = try TraceCorrelation(runID:UUID()),spy = TraceToolFixture()
        let (gateway,action) = try Self.gateway(spy,actor:UUID(),run:UUID())
        _ = try await recorder.withTrace(correlation) { _ in try await gateway.invoke(action) }
        let snapshot = await recorder.snapshot();XCTAssertEqual(snapshot.spans.count,1);XCTAssertEqual(snapshot.droppedSpans,1)
        let bad = TraceToolFixture(malformed:true),(invalid,invalidAction) = try Self.gateway(bad,actor:UUID(),run:correlation.runID)
        do { _ = try await recorder.withTrace(try TraceCorrelation(runID:correlation.runID)) { _ in try await invalid.invoke(invalidAction) };XCTFail("Catalog validation disappeared") }
        catch { XCTAssertEqual(error as? ToolError,.invalidOutput) }
        let later = await recorder.snapshot();try Self.assertPrivate(later)
    }
    func testJournalAndProjectionPreserveProvenanceAndOnlyRecordTypedReferences() async throws {
        let recorder = try Self.recorder(),correlation = try TraceCorrelation(runID:UUID()),port = TraceWorldFixture(),event = try Self.draft(correlation:correlation.traceID)
        let journal = TracedWorldRepository(port),projection = TracedWorldProjector(port)
        let appended = try await recorder.withTrace(correlation) { _ in
            let result = try await journal.append(event,expectedVersion:0,idempotencyKey:"SECRET_journal_key",deadline:.now.advanced(by:.seconds(3)))
            let page = try await journal.page(actorID:event.actorID,limit:1,deadline:.now.advanced(by:.seconds(3)))
            XCTAssertEqual(page.events.first?.draft.id,event.id)
            try await projection.apply(result.event)
            let checkpoint = try await projection.checkpoint();XCTAssertEqual(checkpoint.lastSequence,17)
            return result
        }
        XCTAssertEqual(appended.event.draft,event);XCTAssertEqual(appended.event.draft.confidence.value,0.75)
        let counts = await [port.appendCalls,port.pageCalls,port.applyCalls,port.checkpointCalls],key = await port.lastKey
        XCTAssertEqual(counts,[1,1,1,1]);XCTAssertEqual(key,"SECRET_journal_key")
        let snapshot = await recorder.snapshot();XCTAssertEqual(snapshot.spans.count,5)
        let references = snapshot.spans.filter { $0.attributes["squidra.event_id"] == event.id.uuidString.lowercased() }
        XCTAssertEqual(references.count,2);XCTAssertTrue(references.allSatisfy { $0.attributes["squidra.world_sequence"] == "17" })
        try Self.assertPrivate(snapshot)
    }
    func testNoAmbientSessionDelegatesWithoutTraceAndFailedJournalKeepsOriginalError() async throws {
        XCTAssertNil(TraceSession.current)
        let recorder = try Self.recorder(),model = TraceModelFixture(),request = try Self.request()
        _ = try await TracedLanguageModel(model).generate(request)
        let port = TraceWorldFixture(),plainJournal = TracedWorldRepository(port),plainProjection = TracedWorldProjector(port)
        let plainEvent = try Self.draft(correlation:UUID())
        let appended = try await plainJournal.append(plainEvent,expectedVersion:0,idempotencyKey:"SECRET_plain_key",deadline:.now.advanced(by:.seconds(3)))
        _ = try await plainJournal.page(actorID:plainEvent.actorID,deadline:.now.advanced(by:.seconds(3)))
        try await plainProjection.apply(appended.event);_ = try await plainProjection.checkpoint()
        let tool = TraceToolFixture(),(gateway,action) = try Self.gateway(tool,actor:UUID(),run:UUID())
        _ = try await gateway.invoke(action)
        let plainCounts = await [port.appendCalls,port.pageCalls,port.applyCalls,port.checkpointCalls],toolCalls = await tool.calls
        XCTAssertEqual(plainCounts,[1,1,1,1]);XCTAssertEqual(toolCalls,1)
        let snapshot = await recorder.snapshot();XCTAssertTrue(snapshot.spans.isEmpty)
        let failed = TraceWorldFixture(fail:true),journal = TracedWorldRepository(failed),correlation = try TraceCorrelation(runID:UUID()),event = try Self.draft(correlation:UUID())
        do { _ = try await recorder.withTrace(correlation) { _ in try await journal.append(event,expectedVersion:0,idempotencyKey:"SECRET_key",deadline:.now.advanced(by:.seconds(3))) };XCTFail("Failure disappeared") }
        catch { XCTAssertEqual((error as NSError).domain,"SECRET_journal_error") }
        let later = await recorder.snapshot();XCTAssertTrue(later.spans.allSatisfy { $0.outcome == "failed" });try Self.assertPrivate(later)
        XCTAssertNil(TraceSession.current)
    }
    func testProviderCancellationIsJoinedAndRecordedWithoutChangingError() async throws {
        let recorder = try Self.recorder(),model = TraceModelFixture(.slow),router = try Self.router(model),correlation = try TraceCorrelation(runID:UUID()),request = try Self.request()
        let task = Task { try await recorder.withTrace(correlation) { _ in try await router.generate(request) } }
        let deadline = ContinuousClock.now.advanced(by:.seconds(3))
        while await model.calls == 0 { guard ContinuousClock.now < deadline else { throw PrivateTraceError.invalidConfiguration };await Task.yield() }
        task.cancel()
        do { _ = try await task.value;XCTFail("Cancellation disappeared") } catch { XCTAssertTrue(error is CancellationError) }
        let cancelled = await model.cancelled;XCTAssertTrue(cancelled)
        let snapshot = await recorder.snapshot();XCTAssertEqual(snapshot.spans.count,2);XCTAssertTrue(snapshot.spans.allSatisfy { $0.outcome == "cancelled" });try Self.assertPrivate(snapshot)
    }
}
