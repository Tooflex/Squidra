import Foundation

public enum ToolDefinitionError: Error, Equatable, Sendable { case invalidDefinition }

public struct ToolID: Hashable, Sendable {
    public let namespace: String
    public let name: String
    public let version: String
    public var qualifiedName: String { namespace+"."+name }
    public var identifier: String { qualifiedName+"@"+version }

    public init(namespace: String, name: String, version: String) throws {
        func namePart(_ value: String, maximum: Int) -> Bool {
            guard (1...maximum).contains(value.utf8.count), let first = value.utf8.first, (97...122).contains(first) else { return false }
            return value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
        }
        guard namePart(namespace, maximum: 32), namePart(name, maximum: 64), Self.validVersion(version) else { throw ToolDefinitionError.invalidDefinition }
        self.namespace = namespace; self.name = name; self.version = version
    }
    private static func validVersion(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count) else { return false }
        let build = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let release = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = release[0].split(separator: ".", omittingEmptySubsequences: false)
        func numeric(_ token: Substring) -> Bool { !token.isEmpty && token.utf8.allSatisfy { (48...57).contains($0) } }
        func identifier(_ token: Substring) -> Bool {
            !token.isEmpty && token.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
        guard core.count == 3, core.allSatisfy({ numeric($0) && ($0.count == 1 || $0.first != "0") }) else { return false }
        if release.count == 2 {
            guard release[1].split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ identifier($0) && (!numeric($0) || $0.count == 1 || $0.first != "0") }) else { return false }
        }
        if build.count == 2 {
            guard build[1].split(separator: ".", omittingEmptySubsequences: false).allSatisfy(identifier) else { return false }
        }
        return true
    }
}

public enum ToolRisk: Int, Sendable, CaseIterable { case r0, r1, r2, r3, r4 }
public enum ToolIdempotency: Equatable, Sendable { case readOnly, durableLedger, providerKey }

public struct ToolDefinition: Equatable, Sendable {
    public let schemaVersion = "1"
    public let id: ToolID
    public let capability: String
    public let risk: ToolRisk
    public let idempotency: ToolIdempotency
    public let timeoutMilliseconds: Int64
    public let maximumInputBytes: Int
    public let maximumOutputBytes: Int
    public let inputSchema: Data
    public let outputSchema: Data
    public init(id: ToolID, capability: String, risk: ToolRisk, idempotency: ToolIdempotency,
                timeoutMilliseconds: Int64 = 5_000, maximumInputBytes: Int = 65_536, maximumOutputBytes: Int = 65_536,
                inputSchema: Data, outputSchema: Data) throws {
        guard !capability.isEmpty, capability.utf8.count <= 128,
              capability.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [95,46,58].contains($0) }),
              (1...180_000).contains(timeoutMilliseconds), (1...1_048_576).contains(maximumInputBytes),
              (1...1_048_576).contains(maximumOutputBytes), risk.rawValue <= 1 || idempotency != .readOnly else { throw ToolDefinitionError.invalidDefinition }
        self.id = id; self.capability = capability; self.risk = risk; self.idempotency = idempotency
        self.timeoutMilliseconds = timeoutMilliseconds; self.maximumInputBytes = maximumInputBytes
        self.maximumOutputBytes = maximumOutputBytes; self.inputSchema = inputSchema; self.outputSchema = outputSchema
    }
}
