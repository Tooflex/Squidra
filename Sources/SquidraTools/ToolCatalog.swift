import Foundation

public protocol ToolRegistry: Sendable {
    func definition(for id: ToolID) async throws -> ToolDefinition
}

/// Immutable, explicitly versioned registry. It neither discovers executable
/// plugins nor exposes a production grant issuer; SQD-007 supplies the gateway.
public struct ToolCatalog: ToolRegistry {
    private struct Entry: Sendable { let definition: ToolDefinition; let input: ToolSchema; let output: ToolSchema }
    private let entries: [ToolID:Entry]
    public init(definitions: [ToolDefinition]) throws {
        guard definitions.count <= 256 else { throw ToolError.invalidDefinition }
        var entries: [ToolID:Entry] = [:]
        for definition in definitions {
            guard entries[definition.id] == nil else { throw ToolError.duplicate }
            let prefix = "urn:squidra:tool:"+definition.id.identifier
            entries[definition.id] = try Entry(definition: definition,
                input: ToolSchema(data: definition.inputSchema, expectedID: prefix+":input"),
                output: ToolSchema(data: definition.outputSchema, expectedID: prefix+":output"))
        }
        self.entries = entries
    }
    public func definition(for id: ToolID) async throws -> ToolDefinition {
        try Task.checkCancellation()
        guard let entry = entries[id] else { throw ToolError.unknownTool }
        return entry.definition
    }
    /// Returns the exact normalized bytes that policy, grant and adapter share.
    /// This is not a claim of RFC-8785 canonicalization for semantic hashing.
    public func validateInput(_ input: Data, for id: ToolID) throws -> Data {
        guard let entry = entries[id] else { throw ToolError.unknownTool }
        do {
            let value = try BoundedJSON.parse(input, maximumBytes: entry.definition.maximumInputBytes)
            guard entry.input.validate(value) else { throw ToolError.invalidInput }
            return try value.serializedData()
        } catch { throw ToolError.invalidInput }
    }
    public func validateOutput(_ output: Data, for id: ToolID) throws -> UntrustedToolResult {
        guard let entry = entries[id] else { throw ToolError.unknownTool }
        do {
            let value = try BoundedJSON.parse(output, maximumBytes: entry.definition.maximumOutputBytes)
            guard entry.output.validate(value) else { throw ToolError.invalidOutput }
            return try UntrustedToolResult(tool: id, callID: UUID(), payload: value.serializedData())
        } catch { throw ToolError.invalidOutput }
    }
    public func invoke(_ id: ToolID, input: Data, grant: ToolExecutionGrant, executor: any ToolExecutor) async throws -> UntrustedToolResult {
        try Task.checkCancellation()
        guard let entry = entries[id] else { throw ToolError.unknownTool }
        let validated = try validateInput(input, for: id)
        guard entry.definition.risk != .r4, grant.definition == entry.definition, grant.input == validated,
              !grant.idempotencyKey.isEmpty, grant.idempotencyKey.utf8.count <= 256,
              !grant.idempotencyKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              grant.scope.count <= 256, grant.scope.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw ToolError.policyDenied }
        let now = ContinuousClock.now
        guard grant.deadline > now else { throw ToolError.timedOut }
        let deadline = min(grant.deadline, now.advanced(by: .milliseconds(entry.definition.timeoutMilliseconds)))
        let call = ToolCall(actorID: grant.actorID, runID: grant.runID, tool: id, input: validated,
            scope: grant.scope, idempotencyKey: grant.idempotencyKey, deadline: deadline)
        do {
            let output = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try Task.checkCancellation()
                    return try await executor.execute(call)
                }
                group.addTask { try await Task.sleep(until: deadline); throw ToolError.timedOut }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            try Task.checkCancellation()
            return try validateOutput(output, for: id)
        } catch is CancellationError { throw CancellationError() }
        catch ToolError.timedOut { throw ToolError.timedOut }
        catch ToolError.invalidOutput { throw ToolError.invalidOutput }
        catch { throw ToolError.providerFailure }
    }
}
