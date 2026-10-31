import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

private struct HostTraceIDGenerator: IdGenerator {
    let traceID: TraceId
    func generateSpanId() -> SpanId { .random() }
    func generateTraceId() -> TraceId { traceID }
}
/// All SDK providers/builders/live spans remain isolated here. The public
/// facade accepts no prompt, response, header, path, arbitrary tag or error text.
public actor PrivateTraceRecorder {
    private struct ActiveTrace {
        let correlation: TraceCorrelation
        let provider: TracerProviderSdk
        let root: UUID
        var spans: [UUID:any Span]
        var startedCount: Int
    }
    private let limits: TraceLimits
    private let exporter: PrivateMemoryExporter
    private var traces: [UUID:ActiveTrace] = [:]
    private var dropped = 0
    public init(limits: TraceLimits) {
        self.limits = limits; self.exporter = PrivateMemoryExporter(maximumSpans:limits.maximumStoredSpans)
    }
    public func withTrace<Value:Sendable>(_ correlation: TraceCorrelation,
        operation: @Sendable (TraceSession) async throws -> Value) async rethrows -> Value {
        let session = begin(correlation)
        let scope = session.traceToken.flatMap { trace in session.rootToken.map { TraceScope(traceToken:trace,spanToken:$0,depth:1) } }
        do {
            let value = try await TraceAmbient.$session.withValue(session) {
                try await TraceScope.$current.withValue(scope) { try await operation(session) }
            }
            finish(session.traceToken,outcome:Task.isCancelled ? .cancelled : .ok)
            return value
        } catch {
            finish(session.traceToken,outcome:Task.isCancelled || error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }
    private func begin(_ correlation: TraceCorrelation) -> TraceSession {
        guard traces.count < limits.maximumConcurrentTraces,!traces.values.contains(where: { $0.correlation.traceID == correlation.traceID }) else {
            dropped += 1;return TraceSession(correlation:correlation,recorder:self,traceToken:nil,rootToken:nil)
        }
        let hex = correlation.traceID.uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let id = TraceId(idHi:UInt64(hex.prefix(16),radix:16)!,idLo:UInt64(hex.suffix(16),radix:16)!)
        let spanLimits = SpanLimits().settingAttributeCountLimit(16).settingAttributeValueLengthLimit(64).settingEventCountLimit(0).settingLinkCountLimit(0)
        let provider = TracerProviderSdk(idGenerator:HostTraceIDGenerator(traceID:id),resource:Resource(attributes:["service.name":.string("Squidra")]),spanLimits:spanLimits,
            spanProcessors:[PrivateSpanProcessor(exporter:exporter)])
        let span = provider.get(instrumentationName:"Squidra",instrumentationVersion:"1").spanBuilder(spanName:TraceStage.run.rawValue).setNoParent().setActive(false).startSpan()
        setCorrelation(span,correlation)
        let token = UUID(),root = UUID()
        traces[token] = ActiveTrace(correlation:correlation,provider:provider,root:root,spans:[root:span],startedCount:1)
        return TraceSession(correlation:correlation,recorder:self,traceToken:token,rootToken:root)
    }
    internal func startChild(traceToken:UUID?,parent:UUID?,stage:TraceStage,depth:Int) -> UUID? {
        guard let traceToken,let parent,var trace = traces[traceToken],let parentSpan = trace.spans[parent],
              trace.startedCount < limits.maximumSpansPerTrace,depth <= limits.maximumDepth else { dropped += 1;return nil }
        let span = trace.provider.get(instrumentationName:"Squidra",instrumentationVersion:"1").spanBuilder(spanName:stage.rawValue).setParent(parentSpan).setActive(false).startSpan()
        setCorrelation(span,trace.correlation)
        let token = UUID();trace.spans[token] = span;trace.startedCount += 1;traces[traceToken] = trace
        return token
    }
    internal func finishChild(traceToken:UUID?,spanToken:UUID?,outcome:TraceOutcome) {
        guard let traceToken,let spanToken,var trace = traces[traceToken],spanToken != trace.root,
              let span = trace.spans.removeValue(forKey:spanToken) else { return }
        end(span,outcome:outcome);traces[traceToken] = trace
    }
    private func finish(_ token:UUID?,outcome:TraceOutcome) {
        guard let token,let trace = traces.removeValue(forKey:token) else { return }
        for (id,span) in trace.spans where id != trace.root { end(span,outcome:.scopeClosed) }
        if let root = trace.spans[trace.root] { end(root,outcome:outcome) }
        trace.provider.shutdown()
    }
    private func setCorrelation(_ span:any Span,_ correlation:TraceCorrelation) {
        span.setAttribute(key:"squidra.trace_id",value:correlation.traceID.uuidString.lowercased())
        span.setAttribute(key:"squidra.run_id",value:correlation.runID.uuidString.lowercased())
        if let task = correlation.taskID { span.setAttribute(key:"squidra.task_id",value:task.uuidString.lowercased()) }
    }
    private func end(_ span:any Span,outcome:TraceOutcome) {
        span.setAttribute(key:"squidra.outcome",value:outcome.rawValue)
        span.status = outcome == .ok ? .ok : .error(description:outcome.rawValue)
        span.end()
    }
    internal func recordUsage(traceToken:UUID,spanToken:UUID,usage:TraceUsage) {
        guard let span = traces[traceToken]?.spans[spanToken] else { return }
        for (key,value) in [("squidra.input_tokens",usage.inputTokens),("squidra.output_tokens",usage.outputTokens),
                            ("squidra.cost_micro_usd",usage.costMicroUSD.map(Int.init)),("squidra.world_sequence",usage.worldSequence.map(Int.init))] {
            if let value { span.setAttribute(key:key,value:value) }
        }
        for (key,value) in [("squidra.request_id",usage.requestID),("squidra.event_id",usage.eventID),("squidra.ledger_id",usage.ledgerID)] {
            if let value { span.setAttribute(key:key,value:value.uuidString.lowercased()) }
        }
    }
    internal func noteDroppedSpan() { dropped += 1 }
    public func snapshot(clear:Bool = false) -> TraceSnapshot {
        let exported = exporter.snapshot(clear:clear), droppedCount = dropped+exported.dropped
        if clear { dropped = 0 }
        return TraceSnapshot(spans:exported.spans,droppedSpans:droppedCount,activeTraces:traces.count,
            activeSpans:traces.values.reduce(0) { $0+$1.spans.count })
    }
}
