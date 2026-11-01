import Crypto
import Foundation

/// Trusted host admission: must reserve the cloud attempt before returning,
/// cooperate with cancellation and never derive authorization from provider data.
public protocol VisionCloudAdmission: Sendable {
    func authorize(identity: VisionIdentity, request: VisionRequest) async throws
}
public struct FrameImporter: Sendable {
    private let model: any VisionModel
    private let identity: VisionIdentity
    private let cloudAdmission: (any VisionCloudAdmission)?
    public init(model: any VisionModel, cloudAdmission: (any VisionCloudAdmission)? = nil) {
        self.model = model; self.identity = model.identity; self.cloudAdmission = cloudAdmission
    }
    public func ingest(bytes: Data, mediaType: String, context: FrameContext, consent: FrameImportConsent,
                       deadline: ContinuousClock.Instant) async throws -> ImportedFrame {
        try Self.check(deadline)
        try authorize(context, consent: consent)
        // Consent alone does not activate cloud inference. The trusted host must
        // also supply provider qualification and durable spending admission.
        guard identity.deployment != .cloud || cloudAdmission != nil else { throw VisionError.unavailable }
        let image = try PNGFrame(bytes: bytes, mediaType: mediaType)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let effectiveDeadline = min(deadline, .now.advanced(by: .seconds(identity.deployment == .cloud ? 30 : 5)), consent.expiresAt)
        try Self.check(effectiveDeadline)
        let request = VisionRequest(context: context, image: image, imageSHA256: digest, deadline: effectiveDeadline)
        let output: VisionOutput
        do {
            output = try await withThrowingTaskGroup(of: VisionOutput.self) { group in
                group.addTask {
                    if identity.deployment == .cloud {
                        guard let cloudAdmission else { throw VisionError.unavailable }
                        try await cloudAdmission.authorize(identity:identity,request:request)
                        try Self.check(effectiveDeadline)
                        try authorize(context,consent:consent)
                    }
                    guard model.identity == identity else { throw VisionError.invalidOutput }
                    return try await model.detect(request)
                }
                group.addTask { try await ContinuousClock().sleep(until: effectiveDeadline); throw VisionError.timeout }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw VisionError.unavailable }; return value
            }
        } catch is CancellationError { throw Task.isCancelled ? VisionError.cancelled : VisionError.timeout }
        catch let error as VisionError { throw error }
        catch { throw VisionError.unavailable }
        try Self.check(effectiveDeadline)
        try authorize(context, consent: consent)
        guard model.identity == identity, output.identity == identity, output.context == context,
              output.imageSHA256 == digest, output.detections.count <= 128,
              Set(output.detections.map(\.localID)).count == output.detections.count else { throw VisionError.invalidOutput }
        var totalMaskBytes = 0
        for detection in output.detections {
            let box = detection.box, mask = detection.mask
            totalMaskBytes += mask.pixels.count
            guard box.x + box.width <= image.width, box.y + box.height <= image.height,
                  mask.width == image.width, mask.height == image.height,
                  totalMaskBytes <= 8 * 1024 * 1024 else { throw VisionError.invalidOutput }
            // A mask may be irregular, but must contain foreground and remain
            // inside its half-open source-pixel box. No empty positive detection.
            var foreground = false
            for (index, pixel) in mask.pixels.enumerated() where pixel == 1 {
                let x = index % mask.width, y = index / mask.width
                guard x >= box.x, x < box.x + box.width, y >= box.y, y < box.y + box.height else { throw VisionError.invalidOutput }
                foreground = true
            }
            guard foreground else { throw VisionError.invalidOutput }
        }
        try Self.check(effectiveDeadline)
        return ImportedFrame(context: context, identity: identity, imageSHA256: digest,
                             width: image.width, height: image.height, detections: output.detections)
    }
    private func authorize(_ context: FrameContext, consent: FrameImportConsent) throws {
        guard consent.actorID == context.actorID, consent.cameraID == context.cameraID, consent.expiresAt > .now,
              consent.permitsLocalProcessing,
              identity.deployment != .cloud || consent.permitsCloudTransfer else { throw VisionError.consentRequired }
    }
    private static func check(_ deadline: ContinuousClock.Instant) throws {
        guard !Task.isCancelled else { throw VisionError.cancelled }
        guard deadline > .now else { throw VisionError.timeout }
    }
}
