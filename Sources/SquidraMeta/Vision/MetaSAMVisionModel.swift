import Foundation
import SquidraDomain
import SquidraPerception

/// Prepared cloud adapter, not host activation. FrameImporter still refuses
/// unqualified cloud deployment; only its host-bound VisionRequest may reach us.
public struct MetaSAMVisionModel: VisionModel {
    public let identity: VisionIdentity
    private let client: MetaSAMImageClient, concept: String
    public init(concept: String, transport: any MetaResponsesTransport) throws {
        guard (1...128).contains(concept.utf8.count),!concept.trimmingCharacters(in:.whitespaces).isEmpty,
              !concept.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              !concept.contains("<"),!concept.contains(">") else { throw VisionError.invalidDetection }
        self.concept = concept;client = MetaSAMImageClient(transport:transport)
        // This is the hosted alias, not a claimed immutable weight revision.
        identity = try VisionIdentity(modelID:"meta.sam",version:"alias:sam-3.1",deployment:.cloud)
    }
    @concurrent
    public func detect(_ request: VisionRequest) async throws -> VisionOutput {
        do {
            let raw = try await client.segment(image:request.image,concept:concept,permitsCloudImageTransfer:true,deadline:request.deadline)
            let parsed = try SAMImageSegmentation.decode(raw.segmentationText,width:request.image.width,height:request.image.height,deadline:request.deadline)
            let detections = try parsed.map { item in
                // A single downstream score exists only when both sources have a
                // score; use their minimum without pretending missing means zero.
                let score: Confidence?
                if let box = item.boxConfidence,let mask = item.maskConfidence { score = try Confidence(min(box.value,mask.value)) }
                else { score = nil }
                return try VisionDetection(localID:item.localID,label:concept,box:item.box,mask:item.mask,confidence:score,appearance:nil)
            }
            return VisionOutput(identity:identity,context:request.context,imageSHA256:request.imageSHA256,detections:detections)
        } catch is CancellationError { throw VisionError.cancelled }
        catch SAMDecodeError.deadlineExceeded { throw VisionError.timeout }
        catch MetaResponsesError.deadlineExceeded { throw VisionError.timeout }
        catch is SAMDecodeError { throw VisionError.invalidOutput }
        catch { throw VisionError.unavailable }
    }
}
