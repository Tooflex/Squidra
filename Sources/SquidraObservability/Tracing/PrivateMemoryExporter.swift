import Foundation
import NIOConcurrencyHelpers
import OpenTelemetryApi
import OpenTelemetrySdk

internal final class PrivateMemoryExporter: SpanExporter, Sendable {
    private struct State: Sendable { var spans: [ExportedTraceSpan] = []; var dropped = 0 }
    private let state = NIOLockedValueBox(State())
    private let maximumSpans: Int
    init(maximumSpans: Int) { self.maximumSpans = maximumSpans }
    private static let idKeys: Set<String> = ["squidra.trace_id","squidra.run_id","squidra.task_id","squidra.request_id","squidra.event_id","squidra.ledger_id"]
    private static let countKeys: Set<String> = ["squidra.input_tokens","squidra.output_tokens","squidra.cost_micro_usd","squidra.estimated_cost_micro_usd","squidra.world_sequence"]
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        for span in spans {
            guard let stage = TraceStage(rawValue:span.name), span.hasEnded else { drop();continue }
            var attributes: [String:String] = [:]
            for (key,value) in span.attributes {
                if Self.idKeys.contains(key),case .string(let text) = value,let uuid = UUID(uuidString:text) {
                    attributes[key] = uuid.uuidString.lowercased()
                } else if Self.countKeys.contains(key),case .int(let number) = value,number >= 0 {
                    attributes[key] = String(number)
                }
            }
            // Never export SDK error descriptions, events, links, arbitrary
            // resource values, attribute keys or dynamic operation names.
            let rawOutcome: String
            if case .string(let value) = span.attributes["squidra.outcome"] { rawOutcome = value } else { rawOutcome = "failed" }
            let outcome = (TraceOutcome(rawValue:rawOutcome) ?? .failed).rawValue
            attributes["squidra.outcome"] = outcome
            let record = ExportedTraceSpan(traceID:span.traceId.hexString,spanID:span.spanId.hexString,parentSpanID:span.parentSpanId?.hexString,
                stage:stage,outcome:outcome,attributes:attributes,resource:["service.name":"Squidra"],
                startSecondsSince1970:span.startTime.timeIntervalSince1970,endSecondsSince1970:span.endTime.timeIntervalSince1970)
            state.withLockedValue {
                if $0.spans.count < maximumSpans { $0.spans.append(record) } else { $0.dropped += 1 }
            }
        }
        return .success
    }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) async -> SpanExporterResultCode { exportSynchronously(spans) }
    private func exportSynchronously(_ spans: [SpanData]) -> SpanExporterResultCode { export(spans:spans,explicitTimeout:nil) }
    func flush(explicitTimeout: TimeInterval?) async -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) async {}
    private func drop() { state.withLockedValue { $0.dropped += 1 } }
    func snapshot(clear: Bool) -> (spans:[ExportedTraceSpan],dropped:Int) {
        state.withLockedValue { value in
            let result = (value.spans,value.dropped)
            if clear { value.spans.removeAll(keepingCapacity:true);value.dropped = 0 }
            return result
        }
    }
}
/// Synchronous bounded in-process export: no dispatch backlog, global provider,
/// transport, file, environment detection or automatic exception recording.
internal struct PrivateSpanProcessor: SpanProcessor {
    let exporter: PrivateMemoryExporter
    let isStartRequired = false, isEndRequired = true
    func onStart(parentContext: SpanContext?, span: ReadableSpan) {}
    mutating func onEnd(span: ReadableSpan) { _ = exporter.export(spans:[span.toSpanData()],explicitTimeout:nil) }
    mutating func shutdown(explicitTimeout: TimeInterval?) {}
    func forceFlush(timeout: TimeInterval?) {}
}
