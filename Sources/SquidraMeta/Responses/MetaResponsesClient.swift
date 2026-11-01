import Foundation
import SquidraCognition
import SquidraDomain

public enum MetaResponsesError: Error, Equatable, Sendable {
    case invalidRequest, cloudConsentRequired, deadlineExceeded, transportUnavailable
    case unauthorized, forbidden, rateLimited, unavailable, rejected, invalidResponse, incomplete, refused, unsupportedOutput
}
public enum MetaTextModel: String, Sendable { case spark = "muse-spark-1.3", wonder = "muse-wonder-1.0" }
public struct MetaHTTPResponse: Sendable {
    public let status: Int, contentType: String, body: Data
    public init(status: Int, contentType: String, body: Data) { self.status = status;self.contentType = contentType;self.body = body }
}
/// The production transport must enforce the body limit while receiving bytes,
/// honor cancellation/deadline, and refuse redirects. No automatic retries.
/// Credentials belong to that transport, never the JSON body or model messages.
public protocol MetaResponsesTransport: Sendable {
    func post(_ body: Data, maximumResponseBytes: Int, deadline: ContinuousClock.Instant) async throws -> MetaHTTPResponse
}
public struct MetaTextUsage: Equatable, Sendable {
    public let inputTokens: Int, outputTokens: Int, totalTokens: Int
    public let cachedInputTokens: Int?, reasoningOutputTokens: Int?
}
/// Provider usage is not a monetary charge or an immutable model revision.
/// Cost qualification is required before registering this client as a LanguageModel.
public struct MetaTextResult: Equatable, Sendable {
    public let providerResponseID: String, model: MetaTextModel, text: String, usage: MetaTextUsage
}
public struct MetaResponsesClient: Sendable {
    public static let endpoint = URL(string:"https://api.meta.ai/v1/responses")!
    public static let maximumResponseBytes = 262_144
    private let transport: any MetaResponsesTransport
    public let model: MetaTextModel
    public init(model: MetaTextModel = .spark, transport: any MetaResponsesTransport) { self.model = model;self.transport = transport }
    public func generate(messages: [ModelMessage], maximumOutputTokens: Int, cloudConsent: Bool,
                         deadline: ContinuousClock.Instant) async throws -> MetaTextResult {
        try Task.checkCancellation()
        guard cloudConsent else { throw MetaResponsesError.cloudConsentRequired }
        let now = ContinuousClock.now
        guard deadline > now,deadline <= now.advanced(by:.seconds(180)) else { throw MetaResponsesError.deadlineExceeded }
        let body = try MetaResponsesWire.encode(model:model,messages:messages,maximumOutputTokens:maximumOutputTokens)
        do {
            return try await withThrowingTaskGroup(of:MetaTextResult.self) { group in
                group.addTask {
                    let response = try await transport.post(body,maximumResponseBytes:Self.maximumResponseBytes,deadline:deadline)
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw MetaResponsesError.deadlineExceeded }
                    return try MetaResponsesWire.decode(response,model:model,maximumOutputTokens:maximumOutputTokens)
                }
                group.addTask { try await ContinuousClock().sleep(until:deadline);throw MetaResponsesError.deadlineExceeded }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw MetaResponsesError.transportUnavailable };return value
            }
        } catch is CancellationError { if Task.isCancelled { throw CancellationError() };throw MetaResponsesError.deadlineExceeded }
        catch let error as MetaResponsesError { throw error }
        catch { throw MetaResponsesError.transportUnavailable }
    }
}
internal enum MetaResponsesWire {
    static func encode(model: MetaTextModel, messages: [ModelMessage], maximumOutputTokens: Int) throws -> Data {
        guard (1...64).contains(messages.count),(16...4096).contains(maximumOutputTokens),
              messages.reduce(0,{ $0 + $1.content.utf8.count }) <= 65_536,
              messages.allSatisfy({ !$0.content.contains("\0") && $0.role != .tool }) else { throw MetaResponsesError.invalidRequest }
        // ModelMessage has no tool-call ID, so a tool role cannot be represented
        // as function_call_output. Reject it instead of silently raising authority.
        let input = messages.map { message in
            ["role":message.role.rawValue,"content":[["type":message.role == .assistant ? "output_text" : "input_text","text":message.content]]] as [String:Any]
        }
        let fields: [String:Any] = ["model":model.rawValue,"input":input,"max_output_tokens":maximumOutputTokens,
            "store":false,"stream":false,"background":false,"truncation":"disabled","tools":[],
            "reasoning":["effort":"minimal"],
            "text":["format":["type":"json_schema","name":"squidra_object","strict":false,"schema":["type":"object"]]]]
        do {
            let data = try JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys,.withoutEscapingSlashes])
            _ = try JSONDocument(data,maximumBytes:131_072);return data
        } catch { throw MetaResponsesError.invalidRequest }
    }
    private struct Response: Decodable {
        let id: String, object: String, status: String, model: String
        let store: Bool?, background: Bool?
        let output: [Output], usage: Usage
        struct Output: Decodable {
            let type: String, role: String?, status: String?, content: [Content]?
            struct Content: Decodable { let type: String, text: String? }
        }
        struct Usage: Decodable {
            let input_tokens: Int, output_tokens: Int, total_tokens: Int
            let input_tokens_details: InputDetails?, output_tokens_details: OutputDetails?
            struct InputDetails: Decodable { let cached_tokens: Int? }
            struct OutputDetails: Decodable { let reasoning_tokens: Int? }
        }
    }
    static func decode(_ response: MetaHTTPResponse, model: MetaTextModel, maximumOutputTokens: Int) throws -> MetaTextResult {
        switch response.status {
        case 200: break
        case 401: throw MetaResponsesError.unauthorized
        case 403: throw MetaResponsesError.forbidden
        case 429: throw MetaResponsesError.rateLimited
        case 500...599: throw MetaResponsesError.unavailable
        default: throw MetaResponsesError.rejected
        }
        guard response.contentType.split(separator:";",maxSplits:1).first?.trimmingCharacters(in:.whitespaces).lowercased() == "application/json" else { throw MetaResponsesError.invalidResponse }
        let value: Response
        do {
            let document = try JSONDocument(response.body,maximumBytes:MetaResponsesClient.maximumResponseBytes)
            guard document.kind == .object,!document.containsNUL else { throw MetaResponsesError.invalidResponse }
            value = try JSONDecoder().decode(Response.self,from:document.bytes)
        } catch { throw MetaResponsesError.invalidResponse }
        guard value.object == "response",value.model == model.rawValue,value.store != true,value.background != true,
              value.id.hasPrefix("resp_"),(6...256).contains(value.id.utf8.count),
              value.id.utf8.allSatisfy({ (48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||[45,95].contains($0) }) else { throw MetaResponsesError.invalidResponse }
        guard value.status == "completed" else { throw MetaResponsesError.incomplete }
        let usage = value.usage
        guard (0...1_048_576).contains(usage.input_tokens),(0...maximumOutputTokens).contains(usage.output_tokens),
              usage.total_tokens == usage.input_tokens + usage.output_tokens,
              usage.input_tokens_details?.cached_tokens.map({ (0...usage.input_tokens).contains($0) }) ?? true,
              usage.output_tokens_details?.reasoning_tokens.map({ (0...usage.output_tokens).contains($0) }) ?? true,
              (1...32).contains(value.output.count) else { throw MetaResponsesError.invalidResponse }
        var result = "",messages = 0
        for item in value.output {
            if item.type == "reasoning" { continue } // Never forward hidden reasoning into the answer or traces.
            guard item.type == "message",item.role == "assistant" else { throw MetaResponsesError.unsupportedOutput }
            guard item.status == "completed",let content = item.content,(1...16).contains(content.count) else { throw MetaResponsesError.incomplete }
            messages += 1
            guard messages == 1 else { throw MetaResponsesError.unsupportedOutput }
            for block in content {
                if block.type == "refusal" { throw MetaResponsesError.refused }
                guard block.type == "output_text",let text = block.text else { throw MetaResponsesError.unsupportedOutput }
                result += text
                guard result.utf8.count <= 65_536 else { throw MetaResponsesError.invalidResponse }
            }
        }
        guard messages == 1 else { throw MetaResponsesError.incomplete }
        do { let json = try JSONDocument(Data(result.utf8));guard json.kind == .object,!json.containsNUL else { throw MetaResponsesError.invalidResponse } }
        catch { throw MetaResponsesError.invalidResponse }
        return MetaTextResult(providerResponseID:value.id,model:model,text:result,
            usage:MetaTextUsage(inputTokens:usage.input_tokens,outputTokens:usage.output_tokens,totalTokens:usage.total_tokens,
                cachedInputTokens:usage.input_tokens_details?.cached_tokens,reasoningOutputTokens:usage.output_tokens_details?.reasoning_tokens))
    }
}
