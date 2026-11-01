import Foundation
import SquidraCognition
import SquidraDomain

/// Host-owned cumulative budget. Implementations must atomically persist a unique
/// reservation before returning, cooperate with cancellation/deadlines, and retain
/// it after failures or uncertain results. No estimate-based refund is permitted.
/// The request ID is correlation only: planning and answering may share it.
public protocol MetaAttemptBudget: Sendable {
    func reserve(attemptID: UUID, requestID: UUID, model: MetaTextModel,
                 maximumCostMicroUSD: Int64, deadline: ContinuousClock.Instant) async throws
}

/// An explicit host attestation, not automatic provider qualification. The host
/// must review account terms/failed-call charges and supply a conservative bound.
/// The published worst-context estimate is only a minimum sanity check.
public struct MetaTextQualification: Sendable {
    public let model: MetaTextModel
    public let maximumCostMicroUSD: Int64
    public let validUntil: UTCInstant
    public init(model: MetaTextModel, maximumCostMicroUSD: Int64, validUntil: UTCInstant) throws {
        let maximum = try MetaTextPricing.estimate(model:model,usage:MetaTextUsage(inputTokens:1_048_576,
            outputTokens:4096,totalTokens:1_052_672,cachedInputTokens:nil,reasoningOutputTokens:nil))
        guard maximumCostMicroUSD >= maximum.costMicroUSD else { throw ModelRoutingError.invalidConfiguration }
        self.model = model;self.maximumCostMicroUSD = maximumCostMicroUSD;self.validUntil = validUntil
    }
}

public struct MetaLanguageModel: LanguageModel {
    public let descriptor: ModelDescriptor
    private let qualification: MetaTextQualification
    private let budget: any MetaAttemptBudget
    private let clock: any SquidraDomain.Clock
    private let client: MetaResponsesClient

    public init(qualification: MetaTextQualification, transport: any MetaResponsesTransport,
                budget: any MetaAttemptBudget, clock: any SquidraDomain.Clock) {
        self.qualification = qualification;self.budget = budget;self.clock = clock
        client = MetaResponsesClient(model:qualification.model,transport:transport)
        descriptor = ModelDescriptor(id:qualification.model.rawValue,modelVersion:"alias:"+qualification.model.rawValue,
            location:.cloud,capabilities:[.text,.structuredOutput],maximumCostMicroUSD:qualification.maximumCostMicroUSD)
    }
    @concurrent
    public func generate(_ request: ModelRequest) async throws -> ModelResponse {
        try Task.checkCancellation()
        guard request.schemaVersion == "1" else { throw ModelRoutingError.unsupportedSchemaVersion }
        guard request.cloudConsent else { throw ModelRoutingError.privacyDenied }
        guard !request.requiredCapabilities.isEmpty,request.requiredCapabilities.isSubset(of:descriptor.capabilities) else {
            throw ModelRoutingError.unsupportedCapabilities
        }
        guard request.maximumCostMicroUSD >= qualification.maximumCostMicroUSD else { throw ModelRoutingError.budgetExceeded }
        let now: UTCInstant
        do { now = try clock.now() } catch { throw ModelRoutingError.clockUnavailable }
        let remaining = request.deadline.secondsSince1970-now.secondsSince1970
        guard remaining > 0 else { throw ModelRoutingError.deadlineExceeded }
        guard remaining <= 180 else { throw ModelRoutingError.invalidRequest }
        guard request.deadline <= qualification.validUntil,now < qualification.validUntil else { throw ModelRoutingError.invalidConfiguration }
        // Validate the complete request before charging a reservation. The client
        // repeats this validation at dispatch. Tool results have no call IDs in
        // the domain port: carry them as quoted user-level data, never system
        // instructions or fabricated function-call output. Host validation still
        // controls all claims, permissions and tool execution.
        guard (1...64).contains(request.messages.count),request.messages.reduce(0,{ $0+$1.content.utf8.count }) <= 65_536,
              request.messages.allSatisfy({ !$0.content.contains("\0") }) else { throw ModelRoutingError.invalidRequest }
        let messages = try request.messages.map { message in
            guard message.role == .tool else { return message }
            let data = try JSONSerialization.data(withJSONObject:["kind":"untrusted_tool_data","content":message.content],options:[.sortedKeys,.withoutEscapingSlashes])
            return ModelMessage(role:.user,content:String(decoding:data,as:UTF8.self))
        }
        _ = try MetaResponsesWire.encode(model:qualification.model,messages:messages,maximumOutputTokens:request.maximumOutputTokens)
        let deadline = ContinuousClock.now.advanced(by:.seconds(remaining))
        do {
            return try await withThrowingTaskGroup(of:ModelResponse.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    try await budget.reserve(attemptID:UUID(),requestID:request.id,model:qualification.model,
                        maximumCostMicroUSD:qualification.maximumCostMicroUSD,deadline:deadline)
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw ModelRoutingError.deadlineExceeded }
                    let result = try await client.generate(messages:messages,maximumOutputTokens:request.maximumOutputTokens,
                        cloudConsent:request.cloudConsent,deadline:deadline)
                    let estimate = try MetaTextPricing.estimate(model:qualification.model,usage:result.usage)
                    guard result.usage.outputTokens > 0,estimate.costMicroUSD <= qualification.maximumCostMicroUSD else {
                        throw ModelRoutingError.invalidResponse
                    }
                    return ModelResponse(requestID:request.id,modelID:descriptor.id,modelVersion:descriptor.modelVersion,
                        text:result.text,outputTokens:result.usage.outputTokens,costMicroUSD:estimate.costMicroUSD,
                        costBasis:estimate.costBasis,costRateID:estimate.costRateID)
                }
                group.addTask { try await ContinuousClock().sleep(until:deadline);throw ModelRoutingError.deadlineExceeded }
                guard let response = try await group.next() else { throw ModelProviderError.unavailable };return response
            }
        } catch is CancellationError { throw CancellationError() }
        catch MetaResponsesError.rateLimited { throw ModelProviderError.rateLimited }
        catch MetaResponsesError.unavailable { throw ModelProviderError.unavailable }
        catch MetaResponsesError.transportUnavailable { throw ModelProviderError.unavailable }
        catch MetaResponsesError.deadlineExceeded { throw ModelRoutingError.deadlineExceeded }
    }
}
