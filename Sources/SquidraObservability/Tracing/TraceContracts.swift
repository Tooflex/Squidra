import Foundation

public enum PrivateTraceError: Error, Equatable, Sendable { case invalidConfiguration, invalidCorrelation, invalidUsage }
internal enum TraceOutcome: String, Sendable { case ok, failed, cancelled; case scopeClosed = "scope_closed" }
public enum TraceStage: String, Codable, Sendable { case run, context, planning, model, tool, journal, projection, answer }
public struct TraceCorrelation: Equatable, Sendable {
    public let traceID: UUID, runID: UUID
    public let taskID: UUID?
    public init(traceID: UUID = UUID(), runID: UUID, taskID: UUID? = nil) throws {
        guard traceID.uuidString != "00000000-0000-0000-0000-000000000000" else { throw PrivateTraceError.invalidCorrelation }
        self.traceID = traceID; self.runID = runID; self.taskID = taskID
    }
}
public struct TraceUsage: Sendable {
    public let inputTokens: Int?, outputTokens: Int?, costMicroUSD: Int64?, worldSequence: Int64?
    public let requestID: UUID?, eventID: UUID?, ledgerID: UUID?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, costMicroUSD: Int64? = nil, worldSequence: Int64? = nil,
                requestID: UUID? = nil, eventID: UUID? = nil, ledgerID: UUID? = nil) throws {
        guard inputTokens.map({ (0...1_000_000_000).contains($0) }) ?? true,
              outputTokens.map({ (0...1_000_000_000).contains($0) }) ?? true,
              costMicroUSD.map({ (0...1_000_000_000_000).contains($0) }) ?? true,
              worldSequence.map({ $0 > 0 }) ?? true else { throw PrivateTraceError.invalidUsage }
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.costMicroUSD = costMicroUSD; self.worldSequence = worldSequence
        self.requestID = requestID; self.eventID = eventID; self.ledgerID = ledgerID
    }
}
public struct TraceLimits: Sendable {
    public let maximumConcurrentTraces: Int, maximumSpansPerTrace: Int, maximumDepth: Int, maximumStoredSpans: Int
    public init(maximumConcurrentTraces: Int = 16, maximumSpansPerTrace: Int = 64, maximumDepth: Int = 8, maximumStoredSpans: Int = 4096) throws {
        guard (1...32).contains(maximumConcurrentTraces),(1...256).contains(maximumSpansPerTrace),
              (1...16).contains(maximumDepth),(1...4096).contains(maximumStoredSpans) else { throw PrivateTraceError.invalidConfiguration }
        self.maximumConcurrentTraces = maximumConcurrentTraces; self.maximumSpansPerTrace = maximumSpansPerTrace
        self.maximumDepth = maximumDepth; self.maximumStoredSpans = maximumStoredSpans
    }
}
/// A redacted snapshot of an actual ended SDK span; not an OTLP wire envelope.
public struct ExportedTraceSpan: Codable, Sendable {
    public let traceID: String, spanID: String, parentSpanID: String?
    public let stage: TraceStage
    public let outcome: String
    public let attributes: [String:String]
    public let resource: [String:String]
    public let startSecondsSince1970: Double, endSecondsSince1970: Double
}
public struct TraceSnapshot: Codable, Sendable {
    public let spans: [ExportedTraceSpan]
    public let droppedSpans: Int
    public let activeTraces: Int, activeSpans: Int
}
internal struct TraceScope: Sendable {
    let traceToken: UUID
    let spanToken: UUID?
    let depth: Int
    @TaskLocal static var current: TraceScope?
}
internal enum TraceAmbient { @TaskLocal static var session: TraceSession? }
public struct TraceSession: Sendable {
    public static var current: TraceSession? { TraceAmbient.session }
    public let correlation: TraceCorrelation
    internal let recorder: PrivateTraceRecorder
    internal let traceToken: UUID?
    internal let rootToken: UUID?
    public func withSpan<Value: Sendable>(_ stage: TraceStage,
        operation: @Sendable () async throws -> Value) async rethrows -> Value {
        let current = TraceScope.current
        let parent = current?.traceToken == traceToken ? current?.spanToken : rootToken
        let depth = current?.traceToken == traceToken ? (current?.depth ?? 1)+1 : 2
        let child = await recorder.startChild(traceToken:traceToken,parent:parent,stage:stage,depth:depth)
        let scope = traceToken.map { TraceScope(traceToken:$0,spanToken:child,depth:depth) }
        do {
            let value = try await TraceAmbient.$session.withValue(self) {
                try await TraceScope.$current.withValue(scope) { try await operation() }
            }
            await recorder.finishChild(traceToken:traceToken,spanToken:child,outcome:Task.isCancelled ? .cancelled : .ok)
            return value
        } catch {
            await recorder.finishChild(traceToken:traceToken,spanToken:child,outcome:Task.isCancelled || error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }
    public func recordUsage(_ usage: TraceUsage) async {
        guard let scope = TraceScope.current, let spanToken = scope.spanToken, scope.traceToken == traceToken else { return }
        await recorder.recordUsage(traceToken:scope.traceToken,spanToken:spanToken,usage:usage)
    }
}
