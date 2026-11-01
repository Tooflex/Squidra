import Foundation
import SquidraSecurity

struct BoundaryConfiguration: Sendable, CustomStringConvertible, CustomReflectable {
    enum Invalid: Error { case credential, origin, limits }
    let actorID: UUID
    let approvedOrigin: String
    let maximumBodyBytes: Int
    let requestTimeout: Duration
    let listenHost = "127.0.0.1"
    private let credentialProvider: any CredentialProvider
    private let credentialReference: CredentialReference

    // Inject 32 cryptographically random bytes encoded as 64 lowercase hex characters.
    // Shape validation cannot prove entropy: provisioning is the host's responsibility.
    init(credential: String, actorID: UUID, approvedOrigin: String,
         maximumBodyBytes: Int = 1_048_576, requestTimeout: Duration = .seconds(30)) throws {
        let value: BearerCredential
        do { value = try BearerCredential(credential) } catch { throw Invalid.credential }
        let reference = CredentialReference()
        try self.init(credentialProvider: RotatingCredentialProvider(reference: reference, value: value),
                      credentialReference: reference, actorID: actorID, approvedOrigin: approvedOrigin,
                      maximumBodyBytes: maximumBodyBytes, requestTimeout: requestTimeout)
    }

    init(credentialProvider: any CredentialProvider, credentialReference: CredentialReference,
         actorID: UUID, approvedOrigin: String,
         maximumBodyBytes: Int = 1_048_576, requestTimeout: Duration = .seconds(30)) throws {
        guard let url = URLComponents(string: approvedOrigin),
              ["http", "https"].contains(url.scheme), let host = url.host, !host.isEmpty,
              !approvedOrigin.contains("*"), url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil,
              url.string == approvedOrigin,
              url.port.map({ (1...65535).contains($0) }) ?? true,
              url.scheme == "https" || ["localhost", "127.0.0.1", "[::1]"].contains(host) else {
            throw Invalid.origin
        }
        guard (1...16_777_216).contains(maximumBodyBytes), requestTimeout > .zero,
              requestTimeout <= .seconds(180) else { throw Invalid.limits }
        self.credentialProvider = credentialProvider
        self.credentialReference = credentialReference
        self.actorID = actorID
        self.approvedOrigin = approvedOrigin
        self.maximumBodyBytes = maximumBodyBytes
        self.requestTimeout = requestTimeout
    }

    func authenticates(_ authorization: String?) async throws -> Bool {
        guard let authorization, authorization.utf8.count == 71, authorization.hasPrefix("Bearer ") else { return false }
        let deadline = ContinuousClock.now.advanced(by: min(requestTimeout, .seconds(2)))
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                let value = try await credentialProvider.credential(for: credentialReference, deadline: deadline)
                return value.matches(authorization)
            }
            group.addTask {
                try await ContinuousClock().sleep(until: deadline)
                throw CredentialError.deadlineExceeded
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    var description: String { "BoundaryConfiguration(credential: [REDACTED])" }
    var customMirror: Mirror { Mirror(self, children: ["credential": "[REDACTED]"]) }
}
