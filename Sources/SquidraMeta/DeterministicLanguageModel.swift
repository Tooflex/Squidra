import SquidraCognition

/// Offline development fixture, not a qualified Meta/SAM service or benchmark.
/// It does not access the network or interpret input text as instructions.
public struct DeterministicLanguageModel: LanguageModel {
    public let descriptor: ModelDescriptor

    public init(id: String = "offline-fixture", priority: Int = 0) {
        self.descriptor = ModelDescriptor(id: id, modelVersion: "fixture-1", location: .local,
                                         capabilities: [.text], priority: priority)
    }

    public func generate(_ request: ModelRequest) async throws -> ModelResponse {
        try Task.checkCancellation()
        return ModelResponse(requestID: request.id, modelID: descriptor.id,
                             modelVersion: descriptor.modelVersion, text: "offline-fixture",
                             outputTokens: 1, costMicroUSD: 0, costBasis: .localZero)
    }
}
