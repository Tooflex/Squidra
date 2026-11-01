import Foundation
import PostgresNIO
import SquidraDomain
import SquidraPerception
import SquidraWorld

public enum FramePublicationError: Error, Equatable, Sendable {
    case invalidPolicy, scopeMismatch, unsupportedProfile, invalidDetections, invalidResolution, consentRequired
}
/// Host assertion that a camera observes a named scene. This is not calibration
/// or a transform from pixels to world coordinates. Never decode it from a model.
public struct FrameScenePolicy: Equatable, Sendable {
    public let actorID: UUID, cameraID: UUID, locationID: UUID, coordinateFrameID: UUID
    public let validityMilliseconds: Int
    public let cloudIdentity: VisionIdentity?
    public var deployment: VisionDeployment { cloudIdentity == nil ? .synthetic : .cloud }
    public init(actorID: UUID, cameraID: UUID, locationID: UUID, coordinateFrameID: UUID,
                validityMilliseconds: Int = 1000, cloudIdentity: VisionIdentity? = nil) throws {
        guard (1...1000).contains(validityMilliseconds) else { throw FramePublicationError.invalidPolicy }
        guard cloudIdentity == nil || cloudIdentity?.deployment == .cloud else { throw FramePublicationError.invalidPolicy }
        self.cloudIdentity = cloudIdentity
        self.actorID = actorID; self.cameraID = cameraID; self.locationID = locationID
        self.coordinateFrameID = coordinateFrameID; self.validityMilliseconds = validityMilliseconds
    }
}
/// Source-compatible name for the default synthetic scene policy.
public typealias SyntheticScenePolicy = FrameScenePolicy

public struct FrameIngestionReceipt: Sendable {
    public let resolution: EntityResolution
    public let observation: JournalEvent
    public let locations: [JournalEvent]
    public let created: Bool
    public let recovery: WorldRecoveryReport
}
/// Opt-in host scene composition. Association is a separate durable staging
/// transaction; the immutable evidence batch is atomic. No automatic retry.
public struct PostgresFrameIngestion: Sendable {
    public let policy: FrameScenePolicy
    private let client: PostgresClient, importer: FrameImporter, resolver: ContinuityEntityResolver
    private let identity: VisionIdentity
    public init(client: PostgresClient, model: any VisionModel, policy: FrameScenePolicy,
                cloudAdmission: (any VisionCloudAdmission)? = nil) throws {
        guard model.identity.deployment == policy.deployment,
              policy.cloudIdentity == nil || (model.identity == policy.cloudIdentity && cloudAdmission != nil) else { throw FramePublicationError.unsupportedProfile }
        self.client = client; self.policy = policy; self.identity = model.identity
        importer = FrameImporter(model:model,cloudAdmission:cloudAdmission)
        resolver = ContinuityEntityResolver(store:PostgresEntityAssociationStore(client:client,actorID:policy.actorID,cameraID:policy.cameraID),
            policy:try AssociationPolicy(maximumTracks:32))
    }
    public func ingest(bytes: Data, mediaType: String, context: FrameContext, consent: FrameImportConsent,
                       deadline: ContinuousClock.Instant) async throws -> FrameIngestionReceipt {
        try Task.checkCancellation()
        guard context.actorID == policy.actorID, context.cameraID == policy.cameraID else { throw FramePublicationError.scopeMismatch }
        try authorize(consent)
        let frame = try await importer.ingest(bytes:bytes,mediaType:mediaType,context:context,consent:consent,deadline:deadline)
        guard frame.identity == identity, frame.identity.deployment == policy.deployment else { throw FramePublicationError.unsupportedProfile }
        // The journal requires a known confidence: never invent a score for an
        // unknown detection, and never silently publish only a subset of a frame.
        guard (1...16).contains(frame.detections.count), frame.detections.allSatisfy({ $0.confidence != nil }) else {
            throw FramePublicationError.invalidDetections
        }
        try authorize(consent)
        let resolution = try await resolver.resolve(frame,deadline:deadline)
        guard resolution.context == frame.context, resolution.identity == frame.identity,
              resolution.imageSHA256 == frame.imageSHA256,
              resolution.assignments.map(\.localID) == frame.detections.map(\.localID),
              !resolution.assignments.contains(where:{ $0.entityID == policy.locationID }) else { throw FramePublicationError.invalidResolution }
        let events = try drafts(frame:frame,resolution:resolution)
        try authorize(consent); try Task.checkCancellation()
        let published = try await PostgresWorldRepository(client:client).appendFrame(events,coordinateFrameID:policy.coordinateFrameID,
            deadline:min(deadline,consent.expiresAt,.now.advanced(by:.seconds(4))))
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to:deadline)
        guard remaining > .zero else { throw WorldJournalError.unavailable }
        let report = try await WorldProjectionRecovery(actorID:policy.actorID,repository:PostgresWorldRepository(client:client),
            projector:PostgresLocationProjection(actorID:policy.actorID,client:client),
            limits:WorldRecoveryLimits(timeout:min(remaining,.seconds(5)))).recover()
        guard report.projectedThroughSequence >= published.last!.event.sequence else { throw WorldJournalError.unavailable }
        return FrameIngestionReceipt(resolution:resolution,observation:published[0].event,
            locations:published.dropFirst().map(\.event),created:published[0].created,recovery:report)
    }
    private func authorize(_ consent: FrameImportConsent) throws {
        guard consent.actorID == policy.actorID, consent.cameraID == policy.cameraID,
              consent.permitsLocalProcessing, consent.expiresAt > .now,
              policy.deployment != .cloud || consent.permitsCloudTransfer else { throw FramePublicationError.consentRequired }
    }
    private struct Observation: Encodable {
        let schemaVersion = "1"
        let cameraId: UUID, frameId: UUID, locationId: UUID, coordinateFrameId: UUID
        let modelId: String, modelVersion: String, deployment: String, imageSHA256: String
        let width: Int, height: Int, validityMilliseconds: Int
        let detections: [Detection]
    }
    private struct Detection: Encodable {
        let localId: String, entityId: UUID, label: String, assignment: String
        let confidence: Double, associationScore: Double?
        let x: Int, y: Int, width: Int, height: Int
    }
    private func drafts(frame: ImportedFrame, resolution: EntityResolution) throws -> [WorldEventDraft] {
        let context = frame.context
        let times = try JournalTimes(occurredAt:context.timestamps.occurredAt,observedAt:context.timestamps.observedAt,
            timeZone:context.timestamps.timeZone)
        let detections = zip(frame.detections,resolution.assignments).map { detection,assignment in
            Detection(localId:detection.localID,entityId:assignment.entityID,label:detection.label,assignment:assignment.kind.rawValue,
                confidence:detection.confidence!.value,associationScore:assignment.score,
                x:detection.box.x,y:detection.box.y,width:detection.box.width,height:detection.box.height)
        }
        let payload = Observation(cameraId:context.cameraID,frameId:context.frameID,locationId:policy.locationID,
            coordinateFrameId:policy.coordinateFrameID,modelId:identity.modelID,modelVersion:identity.version,deployment:identity.deployment.rawValue,imageSHA256:frame.imageSHA256,
            width:frame.width,height:frame.height,validityMilliseconds:policy.validityMilliseconds,detections:detections)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let source = identity.deployment.rawValue + "-frame:" + frame.imageSHA256
        // The observation UUID is the host-owned frame UUID. Per-frame stream
        // keys and payload equality preserve replay identity across process restarts.
        var events = [try WorldEventDraft(id:context.frameID,actorID:policy.actorID,streamID:context.frameID,
            entityIDs:resolution.assignments.map(\.entityID)+[policy.locationID],type:"perception.frame_imported",times:times,
            sourceID:source,confidence:Confidence(detections.map(\.confidence).min()!),payloadVersion:1,
            payload:encoder.encode(payload),correlationID:context.frameID)]
        let valid = try FactInterval(fromMicroseconds:times.observedMicroseconds,
            toMicroseconds:times.observedMicroseconds+Int64(policy.validityMilliseconds)*1000)
        for (detection,assignment) in zip(frame.detections,resolution.assignments) {
            let change = LocationFactChange(subjectID:assignment.entityID,locationID:policy.locationID,frameID:policy.coordinateFrameID,
                valid:valid,basis:.inferred)
            events.append(try WorldEventDraft(actorID:policy.actorID,streamID:context.frameID,entityIDs:[assignment.entityID,policy.locationID],
                type:change.eventType,times:times,sourceID:source,confidence:detection.confidence!,payloadVersion:1,
                payload:change.encodedPayload(),causationID:context.frameID,correlationID:context.frameID))
        }
        return events
    }
}
