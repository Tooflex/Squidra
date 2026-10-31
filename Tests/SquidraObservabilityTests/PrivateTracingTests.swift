import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
@testable import SquidraObservability
import XCTest

private actor TraceGate {
    var entered = false
    private var continuation: CheckedContinuation<Void,Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume();continuation = nil }
    func mark() { entered = true }
}
// SAFETY: stateless suite; mutable trace state belongs to actors or locked exporter.
final class PrivateTracingTests: XCTestCase, @unchecked Sendable {
    private static func recorder(_ limits: TraceLimits? = nil) throws -> PrivateTraceRecorder {
        try PrivateTraceRecorder(limits:limits ?? TraceLimits())
    }
    private static func waitForEntry(_ gate: TraceGate) async throws {
        let deadline = ContinuousClock.now.advanced(by:.seconds(3))
        while await !gate.entered {
            guard ContinuousClock.now < deadline else { throw PrivateTraceError.invalidConfiguration };await Task.yield()
        }
    }
    func testActualSDKSpanTreeUsesHostTraceUUIDAndTypedCorrelation() async throws {
        let recorder = try Self.recorder(), correlation = try TraceCorrelation(runID:UUID(),taskID:UUID())
        let value = await recorder.withTrace(correlation) { session in
            await session.withSpan(.planning) {
                await session.withSpan(.model) { 42 }
            }
        }
        XCTAssertEqual(value,42)
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.spans.count,3);XCTAssertEqual(snapshot.activeTraces,0);XCTAssertEqual(snapshot.activeSpans,0);XCTAssertEqual(snapshot.droppedSpans,0)
        let root = try XCTUnwrap(snapshot.spans.first { $0.stage == .run })
        let planning = try XCTUnwrap(snapshot.spans.first { $0.stage == .planning })
        let model = try XCTUnwrap(snapshot.spans.first { $0.stage == .model })
        XCTAssertNil(root.parentSpanID);XCTAssertEqual(planning.parentSpanID,root.spanID);XCTAssertEqual(model.parentSpanID,planning.spanID)
        for span in snapshot.spans {
            XCTAssertEqual(span.traceID,correlation.traceID.uuidString.replacingOccurrences(of:"-",with:"").lowercased())
            XCTAssertEqual(span.spanID.count,16);XCTAssertNotEqual(span.spanID,String(repeating:"0",count:16))
            XCTAssertEqual(span.attributes["squidra.run_id"],correlation.runID.uuidString.lowercased())
            XCTAssertEqual(span.attributes["squidra.task_id"],correlation.taskID?.uuidString.lowercased())
            XCTAssertEqual(span.resource,["service.name":"Squidra"]);XCTAssertEqual(span.outcome,"ok")
            XCTAssertGreaterThanOrEqual(span.endSecondsSince1970,span.startSecondsSince1970)
        }
    }
    func testConcurrentAndNestedTracesKeepTheirOwnParentChains() async throws {
        let recorder = try Self.recorder(TraceLimits(maximumConcurrentTraces:32))
        let correlations = try (0..<16).map { _ in try TraceCorrelation(runID:UUID()) }
        await withTaskGroup(of:Void.self) { group in
            for correlation in correlations {
                group.addTask {
                    await recorder.withTrace(correlation) { session in
                        await session.withSpan(.tool) { await Task.yield() }
                    }
                }
            }
        }
        let outer = try TraceCorrelation(runID:UUID()), inner = try TraceCorrelation(runID:UUID())
        await recorder.withTrace(outer) { session in
            await recorder.withTrace(inner) { nested in await nested.withSpan(.model) {} }
            await session.withSpan(.answer) {}
        }
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.spans.count,36);XCTAssertEqual(snapshot.activeSpans,0)
        for correlation in correlations+[outer,inner] {
            let spans = snapshot.spans.filter { $0.attributes["squidra.run_id"] == correlation.runID.uuidString.lowercased() }
            XCTAssertEqual(spans.count,2)
            let root = try XCTUnwrap(spans.first { $0.stage == .run })
            let child = try XCTUnwrap(spans.first { $0.stage != .run })
            XCTAssertEqual(root.traceID,child.traceID);XCTAssertNil(root.parentSpanID);XCTAssertEqual(child.parentSpanID,root.spanID)
        }
    }
    func testOriginalFailurePropagatesWithoutRecordingDescriptionsOrCanaries() async throws {
        let recorder = try Self.recorder(), correlation = try TraceCorrelation(runID:UUID())
        let canary = "SECRET_PROMPT_HEADER_MEDIA_OUTPUT_ERROR_67ad"
        do {
            try await recorder.withTrace(correlation) { session in
                try await session.withSpan(.model) { throw NSError(domain:canary,code:7,userInfo:[NSLocalizedDescriptionKey:canary]) }
            }
            XCTFail("Error disappeared")
        } catch { XCTAssertEqual((error as NSError).domain,canary) }
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.spans.count,2);XCTAssertTrue(snapshot.spans.allSatisfy { $0.outcome == "failed" })
        XCTAssertEqual(snapshot.activeSpans,0)
        let json = String(decoding:try JSONEncoder().encode(snapshot),as:UTF8.self)
        XCTAssertFalse(json.contains(canary));XCTAssertFalse(json.contains("NSError"));XCTAssertFalse(json.contains("NSLocalizedDescription"))
    }
    func testCancellationClosesChildAndRootWhilePreservingCancellation() async throws {
        let recorder = try Self.recorder(), correlation = try TraceCorrelation(runID:UUID()), gate = TraceGate()
        let task = Task {
            try await recorder.withTrace(correlation) { session in
                try await session.withSpan(.tool) {
                    await gate.mark();try await ContinuousClock().sleep(for:.seconds(30))
                }
            }
        }
        try await Self.waitForEntry(gate);task.cancel()
        do { try await task.value;XCTFail("Cancellation disappeared") } catch { XCTAssertTrue(error is CancellationError) }
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.spans.count,2);XCTAssertTrue(snapshot.spans.allSatisfy { $0.outcome == "cancelled" })
        XCTAssertEqual(snapshot.activeTraces,0);XCTAssertEqual(snapshot.activeSpans,0)
    }
    func testTraceCapacityNeverChangesBusinessResultAndReportsLoss() async throws {
        let recorder = try Self.recorder(TraceLimits(maximumConcurrentTraces:1)), gate = TraceGate()
        let first = try TraceCorrelation(runID:UUID()), second = try TraceCorrelation(runID:UUID())
        let task = Task { await recorder.withTrace(first) { _ in await gate.wait();return 1 } }
        try await Self.waitForEntry(gate)
        let value = await recorder.withTrace(second) { session in await session.withSpan(.tool) { 42 } }
        XCTAssertEqual(value,42)
        await gate.release();let finished = await task.value;XCTAssertEqual(finished,1)
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.spans.count,1);XCTAssertGreaterThanOrEqual(snapshot.droppedSpans,2);XCTAssertEqual(snapshot.activeTraces,0)
    }
    func testDepthSpanAndExportLimitsStayBoundedIncludingDescendantsOfDroppedSpan() async throws {
        let recorder = try Self.recorder(TraceLimits(maximumSpansPerTrace:2,maximumDepth:2,maximumStoredSpans:1))
        let correlation = try TraceCorrelation(runID:UUID())
        let value = await recorder.withTrace(correlation) { session in
            await session.withSpan(.model) {
                await session.withSpan(.tool) { await session.withSpan(.journal) { 7 } }
            }
        }
        XCTAssertEqual(value,7)
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.spans.count,1);XCTAssertEqual(snapshot.spans[0].stage,.model)
        XCTAssertEqual(snapshot.droppedSpans,3);XCTAssertEqual(snapshot.activeSpans,0)
        let cleared = await recorder.snapshot(clear:true);XCTAssertEqual(cleared.spans.count,1)
        let empty = await recorder.snapshot();XCTAssertTrue(empty.spans.isEmpty);XCTAssertEqual(empty.droppedSpans,0)
    }
    func testEscapedSessionCannotReopenTraceAndRootClosesRemainingSpans() async throws {
        let recorder = try Self.recorder(), correlation = try TraceCorrelation(runID:UUID()), gate = TraceGate()
        let worker = try await recorder.withTrace(correlation) { session in
            let worker = Task { await session.withSpan(.tool) { await gate.wait() } }
            try await Self.waitForEntry(gate)
            return worker
        }
        let closed = await recorder.snapshot()
        XCTAssertEqual(closed.activeSpans,0);XCTAssertEqual(closed.spans.count,2)
        XCTAssertEqual(closed.spans.first { $0.stage == .tool }?.outcome,"scope_closed")
        await gate.release();await worker.value
        let escaped = await recorder.withTrace(try TraceCorrelation(runID:UUID())) { $0 }
        let value = await escaped.withSpan(.journal) { 7 };XCTAssertEqual(value,7)
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.activeTraces,0);XCTAssertEqual(snapshot.activeSpans,0)
        XCTAssertEqual(snapshot.spans.count,3);XCTAssertGreaterThanOrEqual(snapshot.droppedSpans,1)
    }
    func testTypedUsagePreservesCountersAndUUIDEvidenceReferences() async throws {
        XCTAssertThrowsError(try TraceUsage(inputTokens:-1));XCTAssertThrowsError(try TraceUsage(costMicroUSD:-1))
        XCTAssertThrowsError(try TraceUsage(outputTokens:1_000_000_001));XCTAssertThrowsError(try TraceUsage(worldSequence:0))
        XCTAssertThrowsError(try TraceLimits(maximumConcurrentTraces:33))
        XCTAssertThrowsError(try TraceCorrelation(traceID:UUID(uuidString:"00000000-0000-0000-0000-000000000000")!,runID:UUID()))
        let recorder = try Self.recorder(), correlation = try TraceCorrelation(runID:UUID())
        let request = UUID(),event = UUID(),ledger = UUID()
        let usage = try TraceUsage(inputTokens:3,outputTokens:5,costMicroUSD:7,worldSequence:Int64.max,requestID:request,eventID:event,ledgerID:ledger)
        await recorder.withTrace(correlation) { session in await session.withSpan(.journal) { await session.recordUsage(usage) } }
        let snapshot = await recorder.snapshot(), span = try XCTUnwrap(snapshot.spans.first { $0.stage == .journal })
        XCTAssertEqual(span.attributes["squidra.input_tokens"],"3");XCTAssertEqual(span.attributes["squidra.output_tokens"],"5")
        XCTAssertEqual(span.attributes["squidra.cost_micro_usd"],"7");XCTAssertEqual(span.attributes["squidra.world_sequence"],String(Int64.max))
        XCTAssertEqual(span.attributes["squidra.event_id"],event.uuidString.lowercased())
        XCTAssertEqual(span.attributes["squidra.request_id"],request.uuidString.lowercased())
        XCTAssertEqual(span.attributes["squidra.ledger_id"],ledger.uuidString.lowercased())
    }
    func testExporterDropsUnmodeledSDKAttributesEventsErrorsResourcesAndStages() throws {
        let exporter = PrivateMemoryExporter(maximumSpans:8),canary = "SECRET_raw_unmodeled_sdk_payload"
        let provider = TracerProviderSdk(resource:Resource(attributes:["unsafe_resource":.string(canary)]),spanProcessors:[PrivateSpanProcessor(exporter:exporter)])
        let span = provider.get(instrumentationName:"test").spanBuilder(spanName:"tool").startSpan()
        span.setAttribute(key:"prompt",value:canary);span.setAttribute(key:"squidra.run_id",value:canary)
        span.addEvent(name:canary);span.status = .error(description:canary);span.end()
        let unsafe = provider.get(instrumentationName:"test").spanBuilder(spanName:canary).startSpan();unsafe.end();provider.shutdown()
        let value = exporter.snapshot(clear:false)
        XCTAssertEqual(value.spans.count,1);XCTAssertEqual(value.dropped,1)
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(value.spans),as:UTF8.self).contains(canary))
        XCTAssertNil(value.spans[0].attributes["prompt"]);XCTAssertNil(value.spans[0].attributes["squidra.run_id"])
    }
}
