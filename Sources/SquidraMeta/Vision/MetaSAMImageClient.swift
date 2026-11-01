import Foundation
import SquidraDomain
import SquidraPerception

/// Raw completed SAM output, not validated geometry or a VisionOutput. The mask
/// codec and host-owned actor/camera identity remain separate boundaries.
public struct MetaSAMImageResult: Equatable, Sendable {
    public let segmentationText: String
    public let imagesProcessed: Int?
}
public struct MetaSAMImageClient: Sendable {
    private let transport: any MetaResponsesTransport
    public init(transport: any MetaResponsesTransport) { self.transport = transport }
    public func segment(image: PNGFrame, concept: String, permitsCloudImageTransfer: Bool,
                        deadline: ContinuousClock.Instant) async throws -> MetaSAMImageResult {
        try Task.checkCancellation()
        guard permitsCloudImageTransfer else { throw MetaResponsesError.cloudConsentRequired }
        guard deadline > .now,deadline <= ContinuousClock.now.advanced(by:.seconds(180)) else { throw MetaResponsesError.deadlineExceeded }
        guard image.bytes.count <= 65_536,image.width <= 1024,image.height <= 1024,
              (1...128).contains(concept.utf8.count),!concept.trimmingCharacters(in:.whitespaces).isEmpty,
              !concept.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              !concept.contains("<"),!concept.contains(">") else { throw MetaResponsesError.invalidRequest }
        let body = try JSONSerialization.data(withJSONObject:[
            "model":"sam-3.1","input":[["type":"message","role":"user","content":[
                ["type":"input_text","text":concept],["type":"input_image","image_url":"data:image/png;base64,"+image.bytes.base64EncodedString()]]]],
            "stream":false,"store":false,"background":false,
            "metadata":["mask_encoding":"one_bit","include_confidence":"true"]],options:[.sortedKeys])
        guard body.count <= 131_072 else { throw MetaResponsesError.invalidRequest }
        do {
            return try await withThrowingTaskGroup(of:MetaSAMImageResult.self) { group in
                group.addTask {
                    let response = try await transport.post(body,maximumResponseBytes:262_144,deadline:deadline)
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw MetaResponsesError.deadlineExceeded }
                    return try Self.decode(response)
                }
                group.addTask { try await ContinuousClock().sleep(until:deadline);throw MetaResponsesError.deadlineExceeded }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw MetaResponsesError.transportUnavailable };return result
            }
        } catch is CancellationError { if Task.isCancelled { throw CancellationError() };throw MetaResponsesError.deadlineExceeded }
        catch let error as MetaResponsesError { throw error }
        catch { throw MetaResponsesError.transportUnavailable }
    }
    private struct Wire: Decodable {
        let object: String, model: String, status: String, output: [Item]
        let store: Bool?, background: Bool?, usage: Usage?
        struct Usage: Decodable { let images_processed: Int? }
        struct Item: Decodable { let type: String, role: String?, status: String?, content: [Part]? }
        struct Part: Decodable { let type: String, text: String? }
    }
    private static func decode(_ response: MetaHTTPResponse) throws -> MetaSAMImageResult {
        switch response.status {
        case 200: break
        case 401: throw MetaResponsesError.unauthorized
        case 403: throw MetaResponsesError.forbidden
        case 429: throw MetaResponsesError.rateLimited
        case 500...599: throw MetaResponsesError.unavailable
        default: throw MetaResponsesError.rejected
        }
        let wire: Wire
        do {
            guard response.contentType.split(separator:";",maxSplits:1).first?.trimmingCharacters(in:.whitespaces).lowercased() == "application/json" else { throw MetaResponsesError.invalidResponse }
            let document = try JSONDocument(response.body,maximumBytes:262_144)
            guard !document.containsNUL else { throw MetaResponsesError.invalidResponse }
            wire = try JSONDecoder().decode(Wire.self,from:response.body)
        } catch { throw MetaResponsesError.invalidResponse }
        guard wire.object == "response",wire.model == "sam-3.1",wire.store != true,wire.background != true,
              wire.usage?.images_processed.map({ $0 == 1 }) ?? true else { throw MetaResponsesError.invalidResponse }
        guard wire.status == "completed" else { throw MetaResponsesError.incomplete }
        // Empty matches still need a completed output-text lane. An absent lane
        // is not evidence that no objects exist in the image.
        guard wire.output.count == 1,let item = wire.output.first,item.type == "message",item.role == "assistant",
              item.status == "completed",let content = item.content,content.count == 1,let part = content.first else { throw MetaResponsesError.unsupportedOutput }
        if part.type == "refusal" { throw MetaResponsesError.refused }
        guard part.type == "output_text",let text = part.text,text.utf8.count <= 196_608 else { throw MetaResponsesError.invalidResponse }
        return MetaSAMImageResult(segmentationText:text,imagesProcessed:wire.usage?.images_processed)
    }
}
