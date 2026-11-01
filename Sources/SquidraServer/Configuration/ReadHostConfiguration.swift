import Foundation
import SquidraAgentRuntime
import SquidraCognition
import SquidraDomain
import SquidraSecurity
import SquidraTools
import SquidraPostgres

/// Explicit host injection. Offline mode never registers a cloud model or
/// silently substitutes fixture responses. Provider qualification is separate.
struct ReadHostConfiguration: Sendable {
    let models: [any LanguageModel], entities: [PlanningEntity]
    let allowSyntheticImportedEntities: Bool
    let cloudConsent: Bool, maximumCostMicroUSD: Int64, maximumOutputTokens: Int
    let budget: RunBudget, freshness: AnswerFreshnessPolicy
    init(models: [any LanguageModel], entities: [PlanningEntity], budget: RunBudget = try! RunBudget(),
         maximumObservationAgeSeconds: Double = 300, minimumConfidence: Double = 0.5, allowSyntheticImportedEntities: Bool = false,
         cloudConsent: Bool = false, maximumCostMicroUSD: Int64 = 0, maximumOutputTokens: Int = 512) throws {
        guard (1...4).contains(models.count),!entities.isEmpty || allowSyntheticImportedEntities else { throw ReadRunSubmissionError.invalidRequest }
        if !entities.isEmpty { _ = try ReadPlanningScope(entities:entities) }
        guard maximumCostMicroUSD >= 0,(16...4096).contains(maximumOutputTokens),cloudConsent || maximumCostMicroUSD == 0 else { throw ModelRoutingError.invalidConfiguration }
        for model in models {
            let d = model.descriptor
            guard d.capabilities.isSuperset(of:[.text,.structuredOutput]) else { throw ModelRoutingError.invalidConfiguration }
            switch d.location {
            case .local: guard d.maximumCostMicroUSD == 0 else { throw ModelRoutingError.invalidConfiguration }
            case .cloud:
                guard cloudConsent,d.maximumCostMicroUSD > 0,d.maximumCostMicroUSD <= maximumCostMicroUSD/2 else { throw ModelRoutingError.invalidConfiguration }
            }
        }
        self.cloudConsent = cloudConsent;self.maximumCostMicroUSD = maximumCostMicroUSD;self.maximumOutputTokens = maximumOutputTokens
        self.allowSyntheticImportedEntities = allowSyntheticImportedEntities
        self.models = models;self.entities = entities;self.budget = budget
        self.freshness = try AnswerFreshnessPolicy(maximumObservationAgeSeconds:maximumObservationAgeSeconds,minimumCurrentConfidence:Confidence(minimumConfidence))
    }
}
/// Process-owned actor/entity authorization. Rebuild on host configuration
/// changes; no model response can extend these grants or register another tool.
struct ServerWorldReadPolicy: PolicyEngine {
    let actorID: UUID, entities: [PlanningEntity]
    func evaluate(_ context: ActionPolicyContext) throws -> ActionPolicyDecision {
        let definitions = try [WorldLocationTool.definition(),WorldChangesTool.definition()]
        let targets = Set(entities.map { "entity:"+$0.id.uuidString.lowercased() })
        let permissions = definitions.map {
            HostActionPermission(actorID:actorID,tool:$0.id,capability:$0.capability,
                targets:targets,scope:["world:read"],expiresAt:context.deadline)
        }
        return try HostActionPolicy(permissions:permissions).evaluate(context)
    }
}


/// Shared admission, execution and recovery lookup. Imported IDs are never
/// added to a process-wide wildcard grant or copied from a model response.
struct ReadHostEntityScope: Sendable {
    let entities: [PlanningEntity]
    let imported: PostgresImportedEntityReadScope?
    func resolve(_ id: UUID, deadline: ContinuousClock.Instant) async throws -> PlanningEntity? {
        if let entity = entities.first(where: { $0.id == id }) { return entity }
        guard let imported,try await imported.contains(id,deadline:deadline) else { return nil }
        return try PlanningEntity(id:id,label:"Imported synthetic entity")
    }
}
struct ScopedServerWorldReadPolicy: PolicyEngine {
    let actorID: UUID, scope: ReadHostEntityScope
    func evaluate(_ context: ActionPolicyContext) async throws -> ActionPolicyDecision {
        guard context.actorID == actorID,context.target.hasPrefix("entity:"),
              let id = UUID(uuidString:String(context.target.dropFirst(7))),
              context.target == "entity:"+id.uuidString.lowercased(),
              let entity = try await scope.resolve(id,deadline:min(context.deadline,.now.advanced(by:.seconds(4)))) else { return .deny }
        return try ServerWorldReadPolicy(actorID:actorID,entities:[entity]).evaluate(context)
    }
}
