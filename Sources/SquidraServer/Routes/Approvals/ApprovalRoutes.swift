import Foundation
import Hummingbird
import SquidraSecurity
import SquidraTools

/// Decisions only persist authorization. This route never invokes an executor.
enum ApprovalRoutes {
    static func mount(_ router: Router<BoundaryContext>, approvals: ApprovalCoordinator, ledger: any ActionLedgerStore) {
        router.get("/api/v1/approvals/:approval") { _,context in
            do {
                let (actor,id) = try identity(context)
                let record = try await approvals.load(actorID:actor,id:id,deadline:.now.advanced(by:.seconds(4)))
                return try await response(record,ledger:ledger)
            } catch { throw mapped(error) }
        }
        router.post("/api/v1/approvals/:approval/decision") { request,context in
            do {
                let (actor,id) = try identity(context)
                guard request.headers[values:.contentType].count == 1,
                      request.headers[.contentType]?.split(separator:";",maxSplits:1).first?.trimmingCharacters(in:.whitespaces).lowercased() == "application/json" else { throw HTTPError(.badRequest) }
                let body = try await request.body.collect(upTo:1_024)
                let (decision,digest) = try parse(Data(body.readableBytesView))
                let record = try await approvals.resolve(actorID:actor,id:id,response:decision,principalID:actor,
                    expectedDigest:digest,deadline:.now.advanced(by:.seconds(4)))
                guard record.decision != .expired else { throw HTTPError(.conflict) }
                if record.decision == .approved {
                    _ = try await approvals.verify(actorID:actor,id:id,binding:record.binding,deadline:.now.advanced(by:.seconds(4)))
                }
                return try await response(record,ledger:ledger)
            } catch { throw mapped(error) }
        }
    }
    private static func identity(_ context: BoundaryContext) throws -> (UUID,UUID) {
        guard let actor = context.actorID else { throw HTTPError(.unauthorized) }
        guard let id = UUID(uuidString:context.parameters.get("approval") ?? "") else { throw HTTPError(.badRequest) }
        return (actor,id)
    }
    private struct Preview: Encodable {
        let schemaVersion = "1"
        let id: UUID, runId: UUID, ledgerId: UUID
        let decision: ApprovalDecision
        let version: Int64
        let digest: String, commandFingerprint: String
        let tool: String, target: String, argumentsJSON: String
        let scope: [String]
        let requestedAt: String, expiresAt: String, decidedAt: String?
    }
    private static func response(_ record: ApprovalRecord, ledger: any ActionLedgerStore) async throws -> Response {
        let action = try await ledger.load(actorID:record.binding.actorID,id:record.binding.ledgerID,deadline:.now.advanced(by:.seconds(4)))
        guard action.command.fingerprint == record.binding.commandHash,action.command.runID == record.binding.runID else { throw ApprovalError.corruptRecord }
        let preview = Preview(id:record.id,runId:record.binding.runID,ledgerId:record.binding.ledgerID,decision:record.decision,version:record.version,
            digest:record.digest.map{String(format:"%02x",$0)}.joined(),commandFingerprint:action.command.fingerprintHex,
            tool:action.command.tool.identifier,target:action.command.target,argumentsJSON:String(decoding:action.command.arguments,as:UTF8.self),
            scope:action.command.scope,requestedAt:utc(record.requestedAtMilliseconds),expiresAt:utc(record.expiresAtMilliseconds),decidedAt:record.decidedAtMilliseconds.map(utc))
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        return try Response(status:.ok,headers:[.contentType:"application/json"],body:.init(byteBuffer:.init(bytes:encoder.encode(preview))))
    }
    private static func utc(_ milliseconds: Int64) -> String {
        let formatter = ISO8601DateFormatter();formatter.timeZone = TimeZone(secondsFromGMT:0)
        formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return formatter.string(from:Date(timeIntervalSince1970:Double(milliseconds)/1_000))
    }
    /// Deliberately closed three-string JSON grammar. Escaped field names/values,
    /// duplicate keys, extra members, arrays and numeric/boolean decisions reject.
    private static func parse(_ data: Data) throws -> (ApprovalResponse,Data) {
        let whitespace = CharacterSet(charactersIn:" \t\r\n")
        guard data.count <= 1_024,let raw = String(data:data,encoding:.utf8) else { throw HTTPError(.badRequest) }
        let text = raw.trimmingCharacters(in:whitespace)
        guard text.first == "{",text.last == "}" else { throw HTTPError(.badRequest) }
        let pairs = text.dropFirst().dropLast().split(separator:",",omittingEmptySubsequences:false)
        guard pairs.count == 3 else { throw HTTPError(.badRequest) }
        var fields: [String:String] = [:]
        for pair in pairs {
            let parts = pair.split(separator:":",omittingEmptySubsequences:false)
            guard parts.count == 2 else { throw HTTPError(.badRequest) }
            func word(_ value: Substring) throws -> String {
                let token = value.trimmingCharacters(in:whitespace)
                guard token.first == "\"",token.last == "\"",token.count >= 2 else { throw HTTPError(.badRequest) }
                let value = String(token.dropFirst().dropLast())
                guard !value.isEmpty,value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw HTTPError(.badRequest) }
                return value
            }
            let key = try word(parts[0]),value = try word(parts[1])
            guard fields.updateValue(value,forKey:key) == nil else { throw HTTPError(.badRequest) }
        }
        guard Set(fields.keys) == ["schemaVersion","decision","digest"],fields["schemaVersion"] == "1",
              let digest = fields["digest"],digest.utf8.count == 64,digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw HTTPError(.badRequest) }
        let response: ApprovalResponse
        switch fields["decision"] { case "approved":response = .approve;case "denied":response = .deny;case "withdrawn":response = .withdraw;default:throw HTTPError(.badRequest) }
        let bytes = Array(digest.utf8)
        let hash = Data(stride(from:0,to:64,by:2).map { UInt8(String(decoding:bytes[$0...$0+1],as:UTF8.self),radix:16)! })
        return (response,hash)
    }
    private static func mapped(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? any HTTPResponseError { return error }
        if let error = error as? ApprovalError {
            switch error {
            case .denied: return HTTPError(.forbidden)
            case .notFound: return HTTPError(.notFound)
            case .invalidRequest: return HTTPError(.badRequest)
            case .conflict,.expired,.notApproved: return HTTPError(.conflict)
            case .corruptRecord,.unavailable: return HTTPError(.serviceUnavailable)
            }
        }
        if let error = error as? ActionLedgerError,error == .notFound { return HTTPError(.notFound) }
        return HTTPError(.serviceUnavailable)
    }
}
