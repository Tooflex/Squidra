import Foundation
import SquidraAgentRuntime
import SquidraCognition
import SquidraObservability

/// A run's trace belongs to its worker, never to the submitting HTTP connection.
/// Successful execution is separate from durable output publication/delivery.
struct TracedReadExecutor: ReadRunAnswerExecuting {
    let base: any ReadRunAnswerExecuting
    let recorder: PrivateTraceRecorder
    func executeAnswer(_ request: ReadRunRequest) async throws -> GroundedAnswer {
        let correlation = try TraceCorrelation(traceID:request.traceID,runID:request.runID,taskID:request.requestID)
        return try await recorder.withTrace(correlation) { session in
            if let usage = try? TraceUsage(requestID:request.requestID) { await session.recordUsage(usage) }
            let answer = try await base.executeAnswer(request)
            // Evidence IDs are emitted only after host grounding validation.
            // These are reference spans, not fabricated journal-read operations.
            for evidence in answer.evidence {
                await session.withSpan(.answer) {
                    if let usage = try? TraceUsage(eventID:evidence.id) { await session.recordUsage(usage) }
                }
            }
            return answer
        }
    }
}
