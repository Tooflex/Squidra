import Crypto
import Foundation
import SquidraDomain
import SquidraPerception

/// Deliberately authored test data. Never an implementation or fallback for SAM.
public struct SyntheticVisionModel: VisionModel {
    public let identity: VisionIdentity
    private let frames: [Frame]
    private struct Fixture: Decodable { let frames: [Frame] }
    private struct Frame: Decodable, Sendable {
        let imageBase64: String, imageSHA256: String
        let width: Int, height: Int
        let detections: [Detection]
    }
    private struct Detection: Decodable, Sendable {
        let localId: String, label: String, mask: String
        let confidence: Double
        let appearance: [Double]
        let box: Box
    }
    private struct Box: Decodable, Sendable { let x: Int, y: Int, width: Int, height: Int }
    public init(fixtureData: Data) throws {
        // Exact repository fixture revision: arbitrary JSON cannot be relabeled
        // as this model. Formatting/content changes require a versioned review.
        guard fixtureData.count <= 32_768,
              Self.digest(fixtureData) == "e26325319492cba42338201a28e7d03980b9fc0fc70c9ed6ca79e560a3e6001a" else { throw VisionError.unavailable }
        do {
            _ = try JSONDocument(fixtureData, maximumBytes: 32_768)
            frames = try JSONDecoder().decode(Fixture.self, from: fixtureData).frames
            identity = try VisionIdentity(modelID: "fixture.vision", version: "1.0.0", deployment: .synthetic)
        } catch { throw VisionError.unavailable }
    }
    public func detect(_ request: VisionRequest) throws -> VisionOutput {
        guard !Task.isCancelled else { throw VisionError.cancelled }
        guard request.deadline > .now else { throw VisionError.timeout }
        guard let frame = frames.first(where: { $0.imageSHA256 == request.imageSHA256 }),
              Self.digest(request.image.bytes) == frame.imageSHA256,
              Data(base64Encoded: frame.imageBase64) == request.image.bytes,
              frame.width == request.image.width, frame.height == request.image.height else { throw VisionError.unavailable }
        let detections = try frame.detections.map { detection in
            try VisionDetection(localID: detection.localId, label: detection.label,
                box: PixelBox(x: detection.box.x, y: detection.box.y, width: detection.box.width, height: detection.box.height),
                mask: BinaryMask(width: frame.width, height: frame.height, pixels: Data(detection.mask.utf8.map { $0 == 49 ? 1 : 0 })),
                confidence: Confidence(detection.confidence), appearance: detection.appearance)
        }
        return VisionOutput(identity: identity, context: request.context, imageSHA256: request.imageSHA256, detections: detections)
    }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
