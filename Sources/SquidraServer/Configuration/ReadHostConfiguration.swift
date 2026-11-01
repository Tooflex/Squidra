import Foundation
import SquidraAgentRuntime
import SquidraCognition
import SquidraDomain
import SquidraSecurity
import SquidraTools

/// Explicit host injection. Offline mode never registers a cloud model or
/// silently substitutes fixture responses. Provider qualification is separate.
struct ReadHostConfiguration: Sendable {
    let models: [any LanguageModel], entities: [PlanningEntity]
    let budget: RunBudget, freshness: AnswerFreshnessPolicy
    init(models: [any LanguageModel], entities: [PlanningEntity], budget: RunBudget = try! RunBudget(),
         maximumObservationAgeSeconds: Double = 300, minimumConfidence: Double = 0.5) throws {
        guard (1...4).contains(models.count),!entities.isEmpty else { throw ReadRunSubmissionError.invalidRequest }
        _ = try ReadPlanningScope(entities:entities)
        for model in models {
            guard case .local = model.descriptor.location,
                  model.descriptor.capabilities.isSuperset(of:[.text,.structuredOutput]),
                  model.descriptor.maximumCostMicroUSD == 0 else { throw ModelRoutingError.invalidConfiguration }
        }
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
