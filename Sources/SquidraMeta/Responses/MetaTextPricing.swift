import SquidraCognition

public struct MetaTextCostEstimate: Equatable, Sendable {
    public let costMicroUSD: Int64
    public let costBasis: ModelCostBasis
    public let costRateID: String
    /// Missing cache detail is charged at the full input rate in this estimate.
    public let cachedInputWasUnknown: Bool
}
/// Frozen Standard text-only schedule observed 2026-11-01. Not an invoice,
/// current-price discovery, account qualification or a per-attempt reservation.
/// No media, tool/search fee, tax, discount or failed-attempt charge is modeled.
public enum MetaTextPricing {
    public static let scheduleID = "meta-standard-text-2026-11-01"
    public static func estimate(model: MetaTextModel, usage: MetaTextUsage) throws -> MetaTextCostEstimate {
        guard (0...1_048_576).contains(usage.inputTokens),(0...4096).contains(usage.outputTokens),
              usage.totalTokens == usage.inputTokens + usage.outputTokens,
              usage.cachedInputTokens.map({ (0...usage.inputTokens).contains($0) }) ?? true,
              usage.reasoningOutputTokens.map({ (0...usage.outputTokens).contains($0) }) ?? true else {
            throw MetaResponsesError.invalidResponse
        }
        // Nano-USD per token, integer arithmetic; bounds above prevent overflow.
        let rates: (input:Int64,cached:Int64,output:Int64)
        switch model {
        case .spark: rates = (1250,150,4250)
        case .wonder: rates = (4000,200,20000)
        }
        let cached = Int64(usage.cachedInputTokens ?? 0)
        let nanoUSD = (Int64(usage.inputTokens)-cached)*rates.input + cached*rates.cached + Int64(usage.outputTokens)*rates.output
        // Round the total up once to a micro-USD. Reasoning is already included
        // in output_tokens and must not be charged a second time.
        return MetaTextCostEstimate(costMicroUSD:(nanoUSD+999)/1000,costBasis:.publishedRateEstimate,
            costRateID:scheduleID,cachedInputWasUnknown:usage.cachedInputTokens == nil)
    }
}
