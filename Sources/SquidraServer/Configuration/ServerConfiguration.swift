import Foundation
import SquidraPostgres
import SquidraSecurity
import SquidraDomain
import SquidraTemporal

struct ServerConfiguration: Sendable {
    enum Invalid: Error { case requiredValues, profile, port, localRunDirectory }
    let boundary: BoundaryConfiguration
    let database: LocalDatabaseConfiguration
    let port: Int
    let localRunDirectory: URL?
    let syntheticImport: SyntheticImportConfiguration?
    let configuredReadHost: ReadHostConfiguration?

    init(environment: [String: String], credentialProvider: (any CredentialProvider)? = nil,
         credentialReference: CredentialReference? = nil, clock: (any SquidraDomain.Clock)? = nil) throws {
        func required(_ key: String) throws -> String {
            guard let value = environment[key], !value.isEmpty else { throw Invalid.requiredValues }
            return value
        }
        let profile = environment["SQUIDRA_PROFILE"] ?? "offline"
        guard ["offline","meta-qualification"].contains(profile) else { throw Invalid.profile }
        let portText = environment["SQUIDRA_PORT"] ?? "8080"
        guard let port = Int(portText), (0...65535).contains(port), String(port) == portText else { throw Invalid.port }
        guard let actor = UUID(uuidString: try required("SQUIDRA_ACTOR_ID")),
              let databasePort = Int(try required("SQUIDRA_DB_PORT")) else { throw Invalid.requiredValues }
        if let path = environment["SQUIDRA_RUN_DIRECTORY"] {
            guard path.hasPrefix("/"),!path.contains("\0"),path.utf8.count <= 4096 else { throw Invalid.localRunDirectory }
            self.localRunDirectory = URL(fileURLWithPath:path,isDirectory:true)
        } else { self.localRunDirectory = nil }
        self.syntheticImport = try SyntheticImportConfiguration.read(environment:environment,actorID:actor)
        if profile == "meta-qualification" {
            configuredReadHost = try MetaReadHostConfiguration.read(environment:environment,allowsImportedEntities:syntheticImport != nil,
                clock:clock ?? SystemClock(timeZone:IANATimeZone(identifier:"Etc/UTC")))
        } else { configuredReadHost = nil }
        self.port = port
        switch (credentialProvider, credentialReference) {
        case let (.some(provider), .some(reference)):
            self.boundary = try BoundaryConfiguration(credentialProvider: provider, credentialReference: reference,
                actorID: actor, approvedOrigin: required("SQUIDRA_UI_ORIGIN"))
        case (.none, .none):
            self.boundary = try BoundaryConfiguration(credential: required("SQUIDRA_AUTH_TOKEN"), actorID: actor,
                approvedOrigin: required("SQUIDRA_UI_ORIGIN"))
        default: throw Invalid.requiredValues
        }
        self.database = try LocalDatabaseConfiguration(port: databasePort, username: required("SQUIDRA_DB_USER"),
            password: required("SQUIDRA_DB_PASSWORD"), database: required("SQUIDRA_DB_NAME"))
    }
}
