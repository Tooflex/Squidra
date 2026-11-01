import Foundation
import SquidraPostgres
import SquidraSecurity

struct ServerConfiguration: Sendable {
    enum Invalid: Error { case requiredValues, profile, port }
    let boundary: BoundaryConfiguration
    let database: LocalDatabaseConfiguration
    let port: Int

    init(environment: [String: String], credentialProvider: (any CredentialProvider)? = nil,
         credentialReference: CredentialReference? = nil) throws {
        func required(_ key: String) throws -> String {
            guard let value = environment[key], !value.isEmpty else { throw Invalid.requiredValues }
            return value
        }
        guard (environment["SQUIDRA_PROFILE"] ?? "offline") == "offline" else { throw Invalid.profile }
        let portText = environment["SQUIDRA_PORT"] ?? "8080"
        guard let port = Int(portText), (0...65535).contains(port), String(port) == portText else { throw Invalid.port }
        guard let actor = UUID(uuidString: try required("SQUIDRA_ACTOR_ID")),
              let databasePort = Int(try required("SQUIDRA_DB_PORT")) else { throw Invalid.requiredValues }
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
