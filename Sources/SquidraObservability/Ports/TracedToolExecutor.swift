import Foundation
import SquidraTools

/// Decorates an already authorized executor call. It cannot mint ToolCall or
/// bypass ActionGateway, catalog schemas, approvals or the durable ledger.
public struct TracedToolExecutor: ToolExecutor {
    private let executor: any ToolExecutor
    public init(_ executor: any ToolExecutor) { self.executor = executor }
    public func execute(_ call: ToolCall) async throws -> Data {
        guard let session = TraceSession.current else { return try await executor.execute(call) }
        guard session.correlation.runID == call.runID else {
            await session.recorder.noteDroppedSpan()
            return try await executor.execute(call)
        }
        return try await session.withSpan(.tool) { try await executor.execute(call) }
    }
}
