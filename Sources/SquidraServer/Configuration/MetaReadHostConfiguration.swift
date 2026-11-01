import Foundation
import SquidraMeta
import SquidraCognition
import SquidraDomain
import SquidraAgentRuntime

/// Opt-in, dated qualification profile. No implicit activation from a key alone.
enum MetaReadHostConfiguration {
    enum Invalid: Error { case consent, model, scope, budget, expired }
    static func read(environment: [String:String], allowsImportedEntities: Bool, clock: any SquidraDomain.Clock,
                     transportFactory: (String) throws -> any MetaResponsesTransport = { try MetaHTTPSResponseTransport(apiKey:$0) }) throws -> ReadHostConfiguration {
        guard environment["SQUIDRA_META_CLOUD_CONSENT"] == "1" else { throw Invalid.consent }
        let selected: MetaTextModel
        switch environment["SQUIDRA_META_MODEL"] {
        case "spark": selected = .spark
        case "wonder": selected = .wonder
        default: throw Invalid.model
        }
        let expires = try UTCInstant(secondsSince1970:MetaFileAttemptBudget.validUntilSeconds)
        // A complete run must fit before the dated qualification expires.
        guard try clock.now().secondsSince1970+180 < expires.secondsSince1970 else { throw Invalid.expired }
        guard let path = environment["SQUIDRA_META_BUDGET_DIRECTORY"],path.hasPrefix("/"),!path.contains("\0"),path.utf8.count <= 4096 else { throw Invalid.budget }
        let entities: [PlanningEntity]
        if let text = environment["SQUIDRA_META_ENTITY_IDS"] {
            let pieces = text.split(separator:",",omittingEmptySubsequences:false)
            guard (1...32).contains(pieces.count),text.utf8.count <= 1183 else { throw Invalid.scope }
            entities = try pieces.map {
                guard let id = UUID(uuidString:String($0)),id.uuidString.lowercased() == $0 else { throw Invalid.scope }
                return try PlanningEntity(id:id,label:"Configured entity")
            }
            guard Set(entities.map(\.id)).count == entities.count else { throw Invalid.scope }
        } else { entities = [] }
        guard !entities.isEmpty || allowsImportedEntities else { throw Invalid.scope }
        let key = try MetaCredentialConfiguration.read(environment:environment)
        let transport = try transportFactory(key)
        let budget = try MetaFileAttemptBudget(directory:URL(fileURLWithPath:path,isDirectory:true),clock:clock)
        let qualification = try MetaTextQualification(model:selected,maximumCostMicroUSD:10_000_000,validUntil:expires)
        let model = MetaLanguageModel(qualification:qualification,transport:transport,budget:budget,clock:clock)
        return try ReadHostConfiguration(models:[model],entities:entities,budget:RunBudget(retries:0),
            allowImportedEntities:allowsImportedEntities,cloudConsent:true,maximumCostMicroUSD:20_000_000,maximumOutputTokens:2048)
    }
}
