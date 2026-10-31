import SquidraCognition

/// Records a physical provider attempt. Router validation remains authoritative;
/// returning from a provider does not imply that its output will be accepted.
public struct TracedLanguageModel: LanguageModel {
    private let model: any LanguageModel
    public var descriptor: ModelDescriptor { model.descriptor }
    public init(_ model: any LanguageModel) { self.model = model }
    public func generate(_ request: ModelRequest) async throws -> ModelResponse {
        guard let session = TraceSession.current else { return try await model.generate(request) }
        return try await session.withSpan(.model) {
            if let usage = try? TraceUsage(requestID:request.id) { await session.recordUsage(usage) }
            let result = try await model.generate(request)
            let descriptor = model.descriptor
            // No arbitrary provider identity enters telemetry, and malformed
            // identity/usage is left untouched for ModelRouter to reject.
            if result.schemaVersion == "1", result.requestID == request.id,
               result.modelID == descriptor.id, result.modelVersion == descriptor.modelVersion,
               result.outputTokens >= 0, result.outputTokens <= request.maximumOutputTokens,
               result.costMicroUSD >= 0, result.costMicroUSD <= descriptor.maximumCostMicroUSD,
               let usage = try? TraceUsage(outputTokens:result.outputTokens,costMicroUSD:result.costMicroUSD) {
                await session.recordUsage(usage)
            }
            return result
        }
    }
}
