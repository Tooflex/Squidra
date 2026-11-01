import Foundation
import SquidraDomain

public enum ModelCapability: String, Hashable, Sendable { case text, structuredOutput, vision }
public enum ModelLocation: Sendable { case local, cloud }
public enum ModelRole: String, Sendable { case system, user, assistant, tool }

public struct ModelMessage: Sendable {
    public let role: ModelRole
    /// Untrusted content. Tool text must never be promoted into a system role.
    public let content: String
    public init(role: ModelRole, content: String) { self.role = role; self.content = content }
}

public struct ModelDescriptor: Sendable {
    public let id: String
    public let modelVersion: String
    public let location: ModelLocation
    public let capabilities: Set<ModelCapability>
    public let priority: Int
    /// Qualified upper bound per attempt, including failed attempts. No live
    /// provider may claim a bound before qualification in T11.
    public let maximumCostMicroUSD: Int64

    public init(id: String, modelVersion: String, location: ModelLocation,
                capabilities: Set<ModelCapability>, priority: Int = 0,
                maximumCostMicroUSD: Int64 = 0) {
        self.id = id; self.modelVersion = modelVersion; self.location = location
        self.capabilities = capabilities; self.priority = priority
        self.maximumCostMicroUSD = maximumCostMicroUSD
    }
}

/// Typed model-port DTO v1, not an HTTP wire envelope. A future adapter must
/// map instants to explicit-offset RFC 3339 under the API DTO schema.
public struct ModelRequest: Sendable {
    public let schemaVersion: String
    public let id: UUID
    public let messages: [ModelMessage]
    public let requiredCapabilities: Set<ModelCapability>
    public let preferredModelID: String?
    public let cloudConsent: Bool
    public let allowFallback: Bool
    public let maximumCostMicroUSD: Int64
    public let maximumOutputTokens: Int
    public let deadline: UTCInstant

    public init(schemaVersion: String = "1", id: UUID, messages: [ModelMessage],
                requiredCapabilities: Set<ModelCapability> = [.text], preferredModelID: String? = nil,
                cloudConsent: Bool = false, allowFallback: Bool = false,
                maximumCostMicroUSD: Int64 = 0, maximumOutputTokens: Int = 256, deadline: UTCInstant) {
        self.schemaVersion = schemaVersion; self.id = id; self.messages = messages
        self.requiredCapabilities = requiredCapabilities; self.preferredModelID = preferredModelID
        self.cloudConsent = cloudConsent; self.allowFallback = allowFallback
        self.maximumCostMicroUSD = maximumCostMicroUSD; self.maximumOutputTokens = maximumOutputTokens
        self.deadline = deadline
    }
}

public struct ModelResponse: Sendable {
    public let schemaVersion: String
    public let requestID: UUID
    public let modelID: String
    public let modelVersion: String
    public let text: String
    public let outputTokens: Int
    /// Monetary amount for this attempt, not the entire run; consult costBasis.
    public let costMicroUSD: Int64
    public let costBasis: ModelCostBasis
    public let costRateID: String?

    public init(schemaVersion: String = "1", requestID: UUID, modelID: String, modelVersion: String,
                text: String, outputTokens: Int, costMicroUSD: Int64,
                costBasis: ModelCostBasis = .unspecified, costRateID: String? = nil) {
        self.schemaVersion = schemaVersion; self.requestID = requestID; self.modelID = modelID
        self.modelVersion = modelVersion; self.text = text; self.outputTokens = outputTokens
        self.costMicroUSD = costMicroUSD
        self.costBasis = costBasis; self.costRateID = costRateID
    }
}

public enum ModelProviderError: Error, Equatable, Sendable { case unavailable, rateLimited }

/// SRS §3.1 ModelPort. Adapters must cooperate with task cancellation and
/// honor request deadlines at their transport boundary; Swift cannot preempt
/// an arbitrary non-cooperative implementation. No tool execution is allowed here.
public protocol LanguageModel: Sendable {
    var descriptor: ModelDescriptor { get }
    func generate(_ request: ModelRequest) async throws -> ModelResponse
}
