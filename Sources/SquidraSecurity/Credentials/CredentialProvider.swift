import Foundation

public enum CredentialError: Error, Equatable, Sendable {
    case invalidValue, unavailable, conflict, deadlineExceeded
}

/// Opaque host reference. Possession alone grants neither authentication nor rotation.
public struct CredentialReference: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// Deliberately not Codable and without a raw-value accessor. Only trusted
/// credential provisioning receives the bearer text; consumers can compare it.
public struct BearerCredential: Sendable, CustomStringConvertible, CustomReflectable {
    private let bytes: [UInt8]
    public init(_ value: String) throws {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CredentialError.invalidValue
        }
        bytes = Array(value.utf8)
    }
    public func matches(_ authorization: String?) -> Bool {
        guard let authorization, authorization.utf8.count == 71, authorization.hasPrefix("Bearer ") else { return false }
        let supplied = Array(authorization.utf8.dropFirst(7))
        var difference: UInt8 = 0
        for index in bytes.indices { difference |= bytes[index] ^ supplied[index] }
        return difference == 0
    }
    public var description: String { "BearerCredential([REDACTED])" }
    public var customMirror: Mirror { Mirror(self, children: ["value": "[REDACTED]"]) }
}

/// SRS SQD-004: injected secret resolution, separate from public configuration.
/// Providers must cooperate with cancellation and honor the monotonic deadline.
public protocol CredentialProvider: Sendable {
    func credential(for reference: CredentialReference, deadline: ContinuousClock.Instant) async throws -> BearerCredential
}

/// In-memory host-owned provisioning adapter. Rotation affects subsequent
/// resolutions; already authenticated requests retain their original authority.
/// No HTTP rotation route or persistent secret storage is exposed.
public actor RotatingCredentialProvider: CredentialProvider, CustomStringConvertible, CustomReflectable {
    private let reference: CredentialReference
    private var value: BearerCredential?
    private var version: UInt64 = 0
    public init(reference: CredentialReference, value: BearerCredential) {
        self.reference = reference; self.value = value
    }
    public func credential(for reference: CredentialReference, deadline: ContinuousClock.Instant) throws -> BearerCredential {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw CredentialError.deadlineExceeded }
        guard reference == self.reference, let value else { throw CredentialError.unavailable }
        return value
    }
    @discardableResult
    public func rotate(_ value: BearerCredential?, reference: CredentialReference,
                       expectedVersion: UInt64) throws -> UInt64 {
        try Task.checkCancellation()
        guard reference == self.reference else { throw CredentialError.unavailable }
        guard expectedVersion == version, version < UInt64.max else { throw CredentialError.conflict }
        self.value = value
        version += 1
        return version
    }
    nonisolated public var description: String { "RotatingCredentialProvider([REDACTED])" }
    nonisolated public var customMirror: Mirror { Mirror(self, children: ["credentials": "[REDACTED]"]) }
}
