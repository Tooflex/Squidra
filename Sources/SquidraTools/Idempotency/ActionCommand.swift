import Crypto
import Foundation
import JSONSchema

/// Frozen fingerprint profile: sorted UTF-8 keys, exact decoded strings and
/// lossless decimal coefficient/exponent normalization. It is not RFC 8785.
public struct ActionCommand: Sendable, Equatable {
    public let actorID: UUID, runID: UUID
    public let tool: ToolID
    public let idempotencyKey: String
    public let target: String
    public let arguments: Data
    public let scope: [String]
    public let fingerprint: Data
    public var fingerprintHex: String { fingerprint.map { String(format: "%02x", $0) }.joined() }

    public init(actorID: UUID, runID: UUID, tool: ToolID, idempotencyKey: String, target: String,
                arguments: Data, scope: [String]) throws {
        guard !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 256,
              idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines) == idempotencyKey,
              !idempotencyKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !target.isEmpty, target.utf8.count <= 2_048,
              target.trimmingCharacters(in: .whitespacesAndNewlines) == target,
              !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), scope.count <= 256,
              scope.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && $0.utf8.allSatisfy({ (33...126).contains($0) }) }) else {
            throw ActionLedgerError.invalidCommand
        }
        do {
            let value = try BoundedJSON.parse(arguments, maximumBytes: 1_048_576)
            guard value.object != nil else { throw ActionLedgerError.invalidCommand }
            self.actorID = actorID; self.runID = runID; self.tool = tool; self.idempotencyKey = idempotencyKey; self.target = target
            self.arguments = try value.serializedData()
            self.scope = Set(scope).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            let fields: JSONValue = ["actor":.string(actorID.uuidString.lowercased()), "tool":.string(tool.qualifiedName),
                "version":.string(tool.version), "target":.string(target), "arguments":value,
                "scope":.array(self.scope.map(JSONValue.string))]
            fingerprint = Data(SHA256.hash(data: Data(("SQUIDRA-ACTION-1\n" + (try Self.canonical(fields))).utf8)))
        } catch { throw ActionLedgerError.invalidCommand }
    }

    private static func canonical(_ value: JSONValue) throws -> String {
        switch value {
        case .object(let object):
            return try "{" + object.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map {
                guard !$0.contains("\0") else { throw ActionLedgerError.invalidCommand }
                return try JSONValue.string($0).serialized() + ":" + canonical(object[$0]!)
            }.joined(separator: ",") + "}"
        case .array(let values): return try "[" + values.map(canonical).joined(separator: ",") + "]"
        case .numberLiteral(let number):
            var raw = number.rawValue.lowercased()
            let negative = raw.hasPrefix("-")
            if negative { raw.removeFirst() }
            let parts = raw.split(separator: "e", omittingEmptySubsequences: false)
            let exponent = parts.count == 2 ? Int(parts[1]) : 0
            guard let exponent, (-10_000...10_000).contains(exponent) else { throw ActionLedgerError.invalidCommand }
            let fraction = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            var digits = fraction.map(String.init).joined()
            let fractionCount = fraction.count == 2 ? fraction[1].count : 0
            let scale = max(0, fractionCount-exponent)
            let significant = digits.drop(while: { $0 == "0" }).count
            let whole = max(1, significant + exponent - fractionCount)
            // JSONB expands exponent notation when read as text. Keep that
            // representation inside the parser's existing 128-byte token limit.
            guard whole + (scale > 0 ? 1+scale : 0) + (negative && !number.isZero ? 1 : 0) <= 128 else {
                throw ActionLedgerError.invalidCommand
            }
            if number.isZero { return "0" }
            var power = exponent - (fraction.count == 2 ? fraction[1].count : 0)
            while digits.first == "0" { digits.removeFirst() }
            while digits.last == "0" { digits.removeLast(); power += 1 }
            return (negative ? "-" : "") + digits + "e" + String(power)
        case .string(let text):
            guard !text.contains("\0") else { throw ActionLedgerError.invalidCommand }
            return try value.serialized()
        default: return try value.serialized()
        }
    }
}
