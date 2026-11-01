import Foundation
import SquidraPerception

/// Dated SAM image profile. Account/media consent belongs to the host and the
/// FrameImporter. This boundary validates the qualified identity/media envelope
/// and reserves the attempt; it does not promise account-wide zero retention.
public struct MetaSAMCloudAdmission: VisionCloudAdmission {
    private let budget: any MetaSAMAttemptBudget
    public init(budget: any MetaSAMAttemptBudget) { self.budget = budget }
    public func authorize(identity: VisionIdentity, request: VisionRequest) async throws {
        try Task.checkCancellation()
        guard identity.deployment == .cloud,identity.modelID == "meta.sam",identity.version == "alias:sam-3.1" else { throw VisionError.unavailable }
        guard request.image.bytes.count <= 65_536,request.image.width <= 1024,request.image.height <= 1024 else { throw VisionError.mediaTooLarge }
        guard request.deadline > .now else { throw VisionError.timeout }
        try await budget.reserveSAM(attemptID:UUID(),frameID:request.context.frameID,deadline:request.deadline)
        try Task.checkCancellation()
        guard request.deadline > .now else { throw VisionError.timeout }
    }
}
