import Foundation

public enum JSONDocumentError: Error, Equatable, Sendable { case invalidDocument }

/// Validated bounded UTF-8 JSON retaining the original bytes, including decimal
/// literals. This is neither schema evaluation nor canonical serialization.
public struct JSONDocument: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case object, array, string, number, boolean, null }
    public let bytes: Data
    public let kind: Kind
    public let containsNUL: Bool
    public init(_ data: Data, maximumBytes: Int = 65_536) throws {
        guard (1...1_048_576).contains(maximumBytes), !data.isEmpty,data.count <= maximumBytes,
              String(data:data,encoding:.utf8) != nil else { throw JSONDocumentError.invalidDocument }
        do {
            var parser = Parser(bytes:Array(data))
            kind = try parser.document();containsNUL = parser.containsNUL;bytes = data
        } catch { throw JSONDocumentError.invalidDocument }
    }
    private struct Parser {
        let bytes: [UInt8]
        var index = 0,nodes = 0
        var containsNUL = false
        var current: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func skipWhitespace() { while let byte = current,[9,10,13,32].contains(byte) { index += 1 } }
        mutating func expect(_ byte: UInt8) throws {
            guard current == byte else { throw JSONDocumentError.invalidDocument };index += 1
        }
        mutating func node() throws {
            nodes += 1;guard nodes <= 4_096 else { throw JSONDocumentError.invalidDocument }
        }
        mutating func document() throws -> Kind {
            skipWhitespace();let kind = try value(depth:0);skipWhitespace()
            guard index == bytes.count else { throw JSONDocumentError.invalidDocument };return kind
        }
        mutating func value(depth: Int) throws -> Kind {
            try node();skipWhitespace()
            guard let byte = current else { throw JSONDocumentError.invalidDocument }
            switch byte {
            case 123:
                guard depth < 32 else { throw JSONDocumentError.invalidDocument }
                index += 1;skipWhitespace();var keys: Set<String> = []
                if current == 125 { index += 1;return .object }
                while true {
                    try node();let key = try string()
                    // Swift's canonical-equivalent key aliases also reject,
                    // conservatively preserving the original tool boundary.
                    guard keys.insert(key).inserted else { throw JSONDocumentError.invalidDocument }
                    skipWhitespace();try expect(58);_ = try value(depth:depth+1);skipWhitespace()
                    if current == 125 { index += 1;return .object }
                    try expect(44);skipWhitespace()
                }
            case 91:
                guard depth < 32 else { throw JSONDocumentError.invalidDocument }
                index += 1;skipWhitespace()
                if current == 93 { index += 1;return .array }
                while true {
                    _ = try value(depth:depth+1);skipWhitespace()
                    if current == 93 { index += 1;return .array }
                    try expect(44);skipWhitespace()
                }
            case 34: _ = try string();return .string
            case 45,48...57: try number();return .number
            case 116: try literal("true");return .boolean
            case 102: try literal("false");return .boolean
            case 110: try literal("null");return .null
            default: throw JSONDocumentError.invalidDocument
            }
        }
        mutating func literal(_ text: String) throws { for byte in text.utf8 { try expect(byte) } }
        mutating func string() throws -> String {
            let start = index;try expect(34)
            while let byte = current {
                if byte == 34 {
                    index += 1
                    let value = try JSONDecoder().decode(String.self,from:Data(bytes[start..<index]))
                    containsNUL = containsNUL || value.contains("\0");return value
                }
                guard byte >= 32 else { throw JSONDocumentError.invalidDocument }
                if byte == 92 {
                    index += 1
                    guard let escaped = current else { throw JSONDocumentError.invalidDocument }
                    if escaped == 117 {
                        index += 1
                        for _ in 0..<4 {
                            guard let hex = current,(48...57).contains(hex) || (65...70).contains(hex) || (97...102).contains(hex) else { throw JSONDocumentError.invalidDocument }
                            index += 1
                        }
                        continue
                    }
                    guard [34,47,92,98,102,110,114,116].contains(escaped) else { throw JSONDocumentError.invalidDocument }
                }
                index += 1
            }
            throw JSONDocumentError.invalidDocument
        }
        func isDigit(_ byte: UInt8?) -> Bool { byte.map { (48...57).contains($0) } ?? false }
        mutating func digits() throws {
            guard isDigit(current) else { throw JSONDocumentError.invalidDocument }
            while isDigit(current) { index += 1 }
        }
        mutating func number() throws {
            let start = index
            if current == 45 { index += 1 }
            if current == 48 {
                index += 1;guard !isDigit(current) else { throw JSONDocumentError.invalidDocument }
            } else { try digits() }
            if current == 46 { index += 1;try digits() }
            if current == 69 || current == 101 {
                index += 1;if current == 43 || current == 45 { index += 1 };try digits()
            }
            guard index-start <= 128,let value = Double(String(decoding:bytes[start..<index],as:UTF8.self)),value.isFinite else { throw JSONDocumentError.invalidDocument }
        }
    }
}
