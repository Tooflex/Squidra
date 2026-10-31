import Foundation
import JSONSchema
import SquidraDomain

/// Shared structural/duplicate limits precede the SDK's schema parser.
internal enum BoundedJSON {
    static func parse(_ data: Data, maximumBytes: Int) throws -> JSONValue {
        do { _ = try JSONDocument(data,maximumBytes:maximumBytes);return try JSONValue.parse(data) }
        catch { throw ToolError.invalidInput }
    }
}

internal struct ToolSchema: Sendable {
    let validator: Schema
    init(data: Data, expectedID: String) throws {
        do {
            let raw = try BoundedJSON.parse(data, maximumBytes: 32_768)
            guard let root = raw.object, root["$schema"]?.string == "https://json-schema.org/draft/2020-12/schema",
                  root["$id"]?.string == expectedID, root["type"]?.string == "object",
                  root["properties"]?.object?["schemaVersion"]?.object?["const"]?.string == "1",
                  root["properties"]?.object?["schemaVersion"]?.object?["type"]?.string == "string",
                  root["required"]?.array?.contains(.string("schemaVersion")) == true else { throw ToolError.unsupportedSchema }
            var nodes = 0
            try Self.check(raw, depth: 0, nodes: &nodes, root: true)
            let original = try Schema(rawSchema: raw, context: .init(dialect: .draft2020_12,
                remoteSchema: [:], formatValidators: DefaultFormatValidators.all.filter { ["uuid","date-time"].contains($0.formatName) }))
            guard try original.validateAgainstMetaSchema().isValid else { throw ToolError.unsupportedSchema }
            var formats: [String:any FormatValidator] = [:]
            let rewritten = try Self.rewriteStringRules(raw, formats: &formats)
            validator = try Schema(rawSchema: rewritten, context: .init(dialect: .draft2020_12,
                remoteSchema: [:], formatValidators: Array(formats.values)))
        } catch { throw ToolError.unsupportedSchema }
    }
    func validate(_ value: JSONValue) -> Bool { validator.validate(value).isValid }

    private struct StringRules: FormatValidator {
        let formatName: String
        let minimum: Int
        let maximum: Int
        let original: (any FormatValidator)?
        func validate(_ value: String) -> Bool {
            let length = value.unicodeScalars.count
            return (minimum...maximum).contains(length) && (original?.validate(value) ?? true)
        }
    }

    /// SDK 0.14.2 uses String.count (graphemes) for lengths. Translate only
    /// those assertions into registered format validators so Unicode code-point
    /// lengths compose correctly inside anyOf/oneOf/allOf without forking it.
    private static func rewriteStringRules(_ raw: JSONValue, formats: inout [String:any FormatValidator]) throws -> JSONValue {
        guard var object = raw.object else { throw ToolError.unsupportedSchema }
        if var properties = object["properties"]?.object {
            for (key, value) in properties { properties[key] = try rewriteStringRules(value, formats: &formats) }
            object["properties"] = .object(properties)
        }
        if let items = object["items"] { object["items"] = try rewriteStringRules(items, formats: &formats) }
        for keyword in ["allOf","anyOf","oneOf"] {
            if let branches = object[keyword]?.array {
                object[keyword] = .array(try branches.map { try rewriteStringRules($0, formats: &formats) })
            }
        }
        if object["type"]?.string == "string" {
            guard let maximum = object["maxLength"]?.integer else { throw ToolError.unsupportedSchema }
            let minimum = object["minLength"]?.integer ?? 0
            let originalName = object["format"]?.string
            let original = DefaultFormatValidators.all.first { $0.formatName == originalName }
            guard originalName == nil || original != nil else { throw ToolError.unsupportedSchema }
            let name = "squidra.string.\(minimum).\(maximum)."+(originalName ?? "plain")
            formats[name] = StringRules(formatName:name,minimum:minimum,maximum:maximum,original:original)
            object.removeValue(forKey: "minLength"); object.removeValue(forKey: "maxLength")
            object["format"] = .string(name)
        }
        return .object(object)
    }

    private static func check(_ raw: JSONValue, depth: Int, nodes: inout Int, root: Bool = false) throws {
        nodes += 1
        guard depth <= 8, nodes <= 256, let object = raw.object else { throw ToolError.unsupportedSchema }
        let metadata: Set<String> = root ? ["$schema","$id","title","description"] : ["title","description"]
        for key in ["title","description"] {
            if let value = object[key] { guard let text = value.string, text.utf8.count <= 500 else { throw ToolError.unsupportedSchema } }
        }
        let compositions = ["allOf","anyOf","oneOf"].filter { object[$0] != nil }
        if let keyword = compositions.first {
            guard !root, compositions.count == 1, Set(object.keys).isSubset(of: metadata.union([keyword])),
                  let branches = object[keyword]?.array, (1...4).contains(branches.count) else { throw ToolError.unsupportedSchema }
            for branch in branches { try check(branch, depth: depth+1, nodes: &nodes) }
            return
        }
        guard let type = object["type"]?.string else { throw ToolError.unsupportedSchema }
        var allowed = metadata.union(["type","enum","const"])
        switch type {
        case "object":
            allowed.formUnion(["properties","required","additionalProperties"])
            guard object["additionalProperties"]?.boolean == false,
                  let properties = object["properties"]?.object, properties.count <= 64,
                  let required = object["required"]?.array,
                  required.allSatisfy({ $0.string.map({ properties[$0] != nil }) ?? false }),
                  Set(required.compactMap(\.string)).count == required.count else { throw ToolError.unsupportedSchema }
            for (key, value) in properties {
                guard !key.isEmpty, key.utf8.count <= 128 else { throw ToolError.unsupportedSchema }
                try check(value, depth: depth+1, nodes: &nodes)
            }
        case "array":
            allowed.formUnion(["items","minItems","maxItems"])
            guard let maximum = object["maxItems"]?.integer, (0...256).contains(maximum), let item = object["items"] else { throw ToolError.unsupportedSchema }
            try bound(object["minItems"], maximum: maximum)
            try check(item, depth: depth+1, nodes: &nodes)
        case "string":
            allowed.formUnion(["minLength","maxLength","format"])
            guard let maximum = object["maxLength"]?.integer, (0...16_384).contains(maximum) else { throw ToolError.unsupportedSchema }
            try bound(object["minLength"], maximum: maximum)
            if let format = object["format"] { guard ["uuid","date-time"].contains(format.string) else { throw ToolError.unsupportedSchema } }
        case "number", "integer":
            allowed.formUnion(["minimum","maximum"])
            guard let minimum = object["minimum"]?.number, let maximum = object["maximum"]?.number,
                  minimum.isFinite, maximum.isFinite, minimum <= maximum else { throw ToolError.unsupportedSchema }
        case "boolean", "null": break
        default: throw ToolError.unsupportedSchema
        }
        guard Set(object.keys).isSubset(of: allowed) else { throw ToolError.unsupportedSchema }
        if let values = object["enum"] { guard let values = values.array, (1...64).contains(values.count) else { throw ToolError.unsupportedSchema } }
    }
    private static func bound(_ raw: JSONValue?, maximum: Int) throws {
        if let raw { guard let value = raw.integer, (0...maximum).contains(value) else { throw ToolError.unsupportedSchema } }
    }
}
