import Foundation
import SquidraDomain

public enum ModelRoutingError: Error, Equatable, Sendable {
    case invalidConfiguration, invalidRequest, unsupportedSchemaVersion
    case unsupportedCapabilities, privacyDenied, budgetExceeded
    case providerUnavailable, fallbackNotPermitted, deadlineExceeded
    case invalidResponse, providerFailure, clockUnavailable
}

public struct RoutedModelResponse: Sendable {
    public let response: ModelResponse
    public let attemptedModelIDs: [String]
    /// Includes conservative reservations for failed attempts; not measured spend.
    public let reservedCostUpperBoundMicroUSD: Int64
}

public struct ModelRouter: Sendable {
    private struct RegisteredModel: Sendable {
        let provider: any LanguageModel
        let descriptor: ModelDescriptor
    }
    private let models: [RegisteredModel]
    private let clock: any SquidraDomain.Clock
    private static let maximumContentBytes = 1_048_576

    public init(models: [any LanguageModel], clock: any SquidraDomain.Clock) throws {
        let registered = models.map { RegisteredModel(provider: $0, descriptor: $0.descriptor) }
        let ids = registered.map { $0.descriptor.id }
        guard Set(ids).count == ids.count,
              registered.allSatisfy({ model in
                  let d = model.descriptor
                  return !d.id.isEmpty && d.id.utf8.count <= 128 && !d.modelVersion.isEmpty
                      && d.modelVersion.utf8.count <= 128 && d.priority >= 0
                      && d.maximumCostMicroUSD >= 0 && !d.capabilities.isEmpty
              }) else { throw ModelRoutingError.invalidConfiguration }
        self.models = registered.sorted {
            if $0.descriptor.priority != $1.descriptor.priority {
                return $0.descriptor.priority < $1.descriptor.priority
            }
            return $0.descriptor.id < $1.descriptor.id
        }
        self.clock = clock
    }

    @concurrent
    public func generate(_ request: ModelRequest) async throws -> RoutedModelResponse {
        try Task.checkCancellation()
        guard request.schemaVersion == "1" else { throw ModelRoutingError.unsupportedSchemaVersion }
        guard !request.messages.isEmpty, request.messages.count <= 64,
              !request.requiredCapabilities.isEmpty, request.maximumCostMicroUSD >= 0,
              (1...1_000_000).contains(request.maximumOutputTokens),
              request.messages.reduce(0, { $0 + $1.content.utf8.count }) <= Self.maximumContentBytes else {
            throw ModelRoutingError.invalidRequest
        }
        let remaining = request.deadline.secondsSince1970 - (try currentTime()).secondsSince1970
        guard remaining > 0 else { throw ModelRoutingError.deadlineExceeded }
        guard remaining <= 180 else { throw ModelRoutingError.invalidRequest }
        // One monotonic timer bounds the entire route, including all fallbacks.
        return try await withThrowingTaskGroup(of: RoutedModelResponse.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await route(request) }
            group.addTask {
                try await Task.sleep(for: .seconds(remaining))
                throw ModelRoutingError.deadlineExceeded
            }
            guard let response = try await group.next() else { throw ModelRoutingError.providerUnavailable }
            return response
        }
    }

    private func currentTime() throws -> UTCInstant {
        do { return try clock.now() }
        catch { throw ModelRoutingError.clockUnavailable }
    }

    private func route(_ request: ModelRequest) async throws -> RoutedModelResponse {
        guard !models.isEmpty else { throw ModelRoutingError.providerUnavailable }
        let capable = models.filter { request.requiredCapabilities.isSubset(of: $0.descriptor.capabilities) }
        guard !capable.isEmpty else { throw ModelRoutingError.unsupportedCapabilities }
        let permitted = capable.filter { $0.descriptor.location == .local || request.cloudConsent }
        guard !permitted.isEmpty else { throw ModelRoutingError.privacyDenied }
        var candidates: [RegisteredModel]
        if let preferred = request.preferredModelID {
            guard let model = models.first(where: { $0.descriptor.id == preferred }) else {
                throw ModelRoutingError.providerUnavailable
            }
            guard request.requiredCapabilities.isSubset(of: model.descriptor.capabilities) else {
                throw ModelRoutingError.unsupportedCapabilities
            }
            guard model.descriptor.location == .local || request.cloudConsent else { throw ModelRoutingError.privacyDenied }
            guard model.descriptor.maximumCostMicroUSD <= request.maximumCostMicroUSD else {
                throw ModelRoutingError.budgetExceeded
            }
            candidates = [model] + permitted.filter { $0.descriptor.id != preferred }
        } else {
            candidates = permitted.filter { $0.descriptor.maximumCostMicroUSD <= request.maximumCostMicroUSD }
            guard !candidates.isEmpty else { throw ModelRoutingError.budgetExceeded }
        }
        var attempted: [String] = []
        var reserved: Int64 = 0
        for (index, model) in candidates.enumerated() {
            try Task.checkCancellation()
            if index > 0 && !request.allowFallback { throw ModelRoutingError.fallbackNotPermitted }
            guard try currentTime() < request.deadline else { throw ModelRoutingError.deadlineExceeded }
            let descriptor = model.descriptor
            guard descriptor.maximumCostMicroUSD <= request.maximumCostMicroUSD - reserved else {
                throw ModelRoutingError.budgetExceeded
            }
            reserved += descriptor.maximumCostMicroUSD
            attempted.append(descriptor.id)
            let response: ModelResponse
            do { response = try await model.provider.generate(request) }
            catch is CancellationError { throw CancellationError() }
            catch let error as ModelProviderError {
                switch error {
                case .unavailable, .rateLimited: continue
                }
            } catch { throw ModelRoutingError.providerFailure }
            try Task.checkCancellation()
            guard try currentTime() < request.deadline else { throw ModelRoutingError.deadlineExceeded }
            guard response.schemaVersion == "1", response.requestID == request.id,
                  response.modelID == descriptor.id, response.modelVersion == descriptor.modelVersion,
                  !response.text.isEmpty, response.text.utf8.count <= Self.maximumContentBytes,
                  response.outputTokens > 0, response.outputTokens <= request.maximumOutputTokens,
                  response.costMicroUSD >= 0, response.costMicroUSD <= descriptor.maximumCostMicroUSD,
                  response.costBasis.validates(amount:response.costMicroUSD,rateID:response.costRateID),
                  response.costBasis != .localZero || descriptor.location == .local else {
                throw ModelRoutingError.invalidResponse
            }
            return RoutedModelResponse(response: response, attemptedModelIDs: attempted,
                                       reservedCostUpperBoundMicroUSD: reserved)
        }
        throw ModelRoutingError.providerUnavailable
    }
}
