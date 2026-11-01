import Foundation
import SquidraMeta
import SquidraCognition
import SquidraDomain
import SquidraAgentRuntime
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Opt-in, dated qualification profile. No implicit activation from a key alone.
enum MetaReadHostConfiguration {
    enum Invalid: Error { case consent, model, scope, credential, budget, expired }
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
        let key: String
        switch (environment["MODEL_API_KEY"],environment["MODEL_API_KEY_FILE"]) {
        case let (.some(value),.none): key = value
        case let (.none,.some(path)): key = try readKey(path)
        default: throw Invalid.credential
        }
        // Validate even with an injected offline transport; never expose the key.
        _ = try MetaHTTPSResponseTransport(apiKey:key)
        let transport = try transportFactory(key)
        let budget = try MetaFileAttemptBudget(directory:URL(fileURLWithPath:path,isDirectory:true),clock:clock)
        let qualification = try MetaTextQualification(model:selected,maximumCostMicroUSD:10_000_000,validUntil:expires)
        let model = MetaLanguageModel(qualification:qualification,transport:transport,budget:budget,clock:clock)
        return try ReadHostConfiguration(models:[model],entities:entities,budget:RunBudget(retries:0),
            allowSyntheticImportedEntities:allowsImportedEntities,cloudConsent:true,maximumCostMicroUSD:20_000_000,maximumOutputTokens:4096)
    }
    private static func readKey(_ path: String) throws -> String {
        guard path.hasPrefix("/"),!path.contains("\0"),path.utf8.count <= 4096 else { throw Invalid.credential }
        let fd = open(path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Invalid.credential };defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_uid == geteuid(),info.st_nlink == 1,
              info.st_mode & 0o7777 == 0o600,(1...4096).contains(info.st_size) else { throw Invalid.credential }
        let data = try FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:4097) ?? Data()
        guard data.count == info.st_size,let key = String(data:data,encoding:.ascii) else { throw Invalid.credential }
        return key
    }
}
