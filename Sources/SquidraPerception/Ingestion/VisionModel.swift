import Foundation
import SquidraDomain

public enum VisionError: Error, Equatable, Sendable {
    case invalidMedia, mediaTooLarge, invalidDetection, consentRequired, unavailable, invalidOutput, timeout, cancelled
}
public enum VisionDeployment: String, Sendable { case synthetic, local, cloud }
public struct VisionIdentity: Equatable, Sendable {
    public let modelID: String
    public let version: String
    public let deployment: VisionDeployment
    public init(modelID: String, version: String, deployment: VisionDeployment) throws {
        for value in [modelID, version] {
            guard !value.isEmpty, value.utf8.count <= 128,
                  value.utf8.allSatisfy({ (33...126).contains($0) }) else { throw VisionError.invalidOutput }
        }
        self.modelID = modelID; self.version = version; self.deployment = deployment
    }
}
/// Host-owned context. No wire decoder or provider may choose these identities.
public struct FrameContext: Equatable, Sendable {
    public let actorID: UUID, cameraID: UUID, frameID: UUID
    public let timestamps: ObservationTimestamps
    public init(actorID: UUID, cameraID: UUID, frameID: UUID, timestamps: ObservationTimestamps) {
        self.actorID = actorID; self.cameraID = cameraID; self.frameID = frameID; self.timestamps = timestamps
    }
}
/// Explicit host policy for this actor/camera, with monotonic expiry.
public struct FrameImportConsent: Sendable {
    public let actorID: UUID, cameraID: UUID
    public let permitsLocalProcessing: Bool, permitsCloudTransfer: Bool
    public let expiresAt: ContinuousClock.Instant
    public init(actorID: UUID, cameraID: UUID, permitsLocalProcessing: Bool, permitsCloudTransfer: Bool,
                expiresAt: ContinuousClock.Instant) {
        self.actorID = actorID; self.cameraID = cameraID; self.permitsLocalProcessing = permitsLocalProcessing
        self.permitsCloudTransfer = permitsCloudTransfer; self.expiresAt = expiresAt
    }
}
public struct PixelBox: Equatable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) throws {
        guard x >= 0, y >= 0, width > 0, height > 0,
              x <= 2048, y <= 2048, width <= 2048, height <= 2048 else { throw VisionError.invalidDetection }
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}
/// One byte per source pixel, exactly 0 or 1. No vendor compression is implied.
public struct BinaryMask: Equatable, Sendable {
    public let width: Int, height: Int
    public let pixels: Data
    public init(width: Int, height: Int, pixels: Data) throws {
        guard (1...2048).contains(width), (1...2048).contains(height),
              pixels.count == width * height, pixels.allSatisfy({ $0 <= 1 }) else { throw VisionError.invalidDetection }
        self.width = width; self.height = height; self.pixels = pixels
    }
}
public struct VisionDetection: Equatable, Sendable {
    public let localID: String, label: String
    public let box: PixelBox
    public let mask: BinaryMask
    public let confidence: Confidence?
    public let appearance: [Double]?
    public init(localID: String, label: String, box: PixelBox, mask: BinaryMask,
                confidence: Confidence?, appearance: [Double]?) throws {
        guard !localID.isEmpty, localID.utf8.count <= 64, !label.isEmpty, label.utf8.count <= 128,
              !localID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              appearance.map({ !$0.isEmpty && $0.count <= 256 && $0.allSatisfy { $0.isFinite && (-1...1).contains($0) } }) ?? true
        else { throw VisionError.invalidDetection }
        self.localID = localID; self.label = label; self.box = box; self.mask = mask
        self.confidence = confidence; self.appearance = appearance
    }
}
public struct VisionRequest: Sendable {
    public let context: FrameContext
    public let image: PNGFrame
    public let imageSHA256: String
    public let deadline: ContinuousClock.Instant
    // Only the ingestion boundary constructs a request after consent validation.
    internal init(context: FrameContext, image: PNGFrame, imageSHA256: String, deadline: ContinuousClock.Instant) {
        self.context = context; self.image = image; self.imageSHA256 = imageSHA256; self.deadline = deadline
    }
}
public struct VisionOutput: Sendable {
    public let identity: VisionIdentity
    public let context: FrameContext
    public let imageSHA256: String
    public let detections: [VisionDetection]
    public init(identity: VisionIdentity, context: FrameContext, imageSHA256: String, detections: [VisionDetection]) {
        self.identity = identity; self.context = context; self.imageSHA256 = imageSHA256; self.detections = detections
    }
}
/// SRS PerceptionPort: implementations must cooperate with cancellation/deadline.
public protocol VisionModel: Sendable {
    var identity: VisionIdentity { get }
    func detect(_ request: VisionRequest) async throws -> VisionOutput
}
/// A validated inference result, without image bytes or persistent entity IDs.
public struct ImportedFrame: Sendable {
    public let context: FrameContext
    public let identity: VisionIdentity
    public let imageSHA256: String
    public let width: Int, height: Int
    public let detections: [VisionDetection]
    public var synthetic: Bool { identity.deployment == .synthetic }
    internal init(context: FrameContext, identity: VisionIdentity, imageSHA256: String,
                  width: Int, height: Int, detections: [VisionDetection]) {
        self.context = context; self.identity = identity; self.imageSHA256 = imageSHA256
        self.width = width; self.height = height; self.detections = detections
    }
}
