import Foundation

struct BoundaryConfiguration: Sendable, CustomStringConvertible, CustomReflectable {
    enum Invalid: Error { case credential, origin, limits }
    let actorID: UUID
    let approvedOrigin: String
    let maximumBodyBytes: Int
    let requestTimeout: Duration
    let listenHost = "127.0.0.1"
    private let credential: [UInt8]

    // Inject 32 cryptographically random bytes encoded as 64 lowercase hex characters.
    // Shape validation cannot prove entropy: provisioning is the host's responsibility.
    init(credential: String, actorID: UUID, approvedOrigin: String,
         maximumBodyBytes: Int = 1_048_576, requestTimeout: Duration = .seconds(30)) throws {
        guard credential.utf8.count == 64,
              credential.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Invalid.credential
        }
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
        self.credential = Array(credential.utf8)
        self.actorID = actorID
        self.approvedOrigin = approvedOrigin
        self.maximumBodyBytes = maximumBodyBytes
        self.requestTimeout = requestTimeout
    }

    func authenticates(_ authorization: String?) -> Bool {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return false }
        let supplied = Array(authorization.utf8.dropFirst(7))
        guard supplied.count == credential.count else { return false }
        // No early exit on differing bytes. This is not a formal constant-time guarantee
        // for Swift compiler output; use TLS and keep this local listener on loopback.
        var difference: UInt8 = 0
        for index in credential.indices { difference |= credential[index] ^ supplied[index] }
        return difference == 0
    }

    var description: String { "BoundaryConfiguration(credential: [REDACTED])" }
    var customMirror: Mirror { Mirror(self, children: ["credential": "[REDACTED]"]) }
}
