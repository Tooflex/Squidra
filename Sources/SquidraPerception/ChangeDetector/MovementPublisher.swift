import Foundation
import SquidraDomain
import SquidraSpatial
import SquidraWorld

public enum MovementPublicationError: Error, Equatable, Sendable { case scopeMismatch, unknownConfidence, capacityExceeded, expired }
public enum MovementEvidenceOrigin: String, Sendable { case synthetic, sensor }

/// Publishes inferred movement evidence, never a location assertion or action.
/// A retry may encounter a committed prefix; deterministic per-event keys reuse
/// that prefix. The entire report is preflighted before any append occurs.
public struct MovementPublisher: Sendable {
    public let actorID: UUID
    private let repository: any WorldRepository
    public init(actorID: UUID, repository: any WorldRepository) { self.actorID = actorID; self.repository = repository }
    public func publish(_ report: MovementReport, origin: MovementEvidenceOrigin,
                        deadline: ContinuousClock.Instant) async throws -> [JournalAppend] {
        guard report.events.count <= 128 else { throw MovementPublicationError.capacityExceeded }
        guard report.events.allSatisfy({ $0.actorID == actorID }),
              report.samples.allSatisfy({ $0.observation.map { $0.actorID == actorID } ?? true }) else { throw MovementPublicationError.scopeMismatch }
        let drafts = try report.events.map { try Self.draft($0,origin: origin) }
        var results: [JournalAppend] = []
        for (event,draft) in zip(report.events,drafts) {
            try Task.checkCancellation()
            guard deadline > .now else { throw MovementPublicationError.expired }
            results.append(try await repository.append(draft,expectedVersion: 0,idempotencyKey: "movement:"+event.id,deadline: deadline))
        }
        return results
    }
    /// Verify the immutable journal event against its sealed original inputs.
    /// Payload comparison tolerates PostgreSQL JSON formatting only.
    public static func validates(_ event: JournalEvent, epoch: MovementEpoch) throws -> Bool {
        guard event.draft.actorID == epoch.detector.actorID,event.draft.correlationID == epoch.detector.epochID else { return false }
        for movement in try epoch.evaluate().events where event.draft.sourceID == "movement:"+movement.id {
            let expected = try draft(movement,origin: epoch.origin),actual = event.draft
            guard expected.id == actual.id,expected.streamID == actual.streamID,expected.entityIDs == actual.entityIDs,
                  expected.type == actual.type,expected.times == actual.times,expected.confidence == actual.confidence,
                  expected.payloadVersion == actual.payloadVersion,expected.causationID == actual.causationID else { return false }
            return try (JSONSerialization.jsonObject(with: expected.payload.bytes) as? NSDictionary) == (JSONSerialization.jsonObject(with: actual.payload.bytes) as? NSDictionary)
        }
        return false
    }
    private static func draft(_ event: ConfirmedMovement, origin: MovementEvidenceOrigin) throws -> WorldEventDraft {
        let sources = [event.baseline]+event.confirmations
        guard sources.allSatisfy({ $0.source.confidence != nil }) else { throw MovementPublicationError.unknownConfidence }
        // Source confidence summary, not a calibrated movement probability.
        let confidence = try Confidence(sources.map { $0.source.confidence!.value }.min()!)
        let hex = Array(event.id.prefix(32))
        let uuidText = String(hex[0..<8])+"-"+String(hex[8..<12])+"-"+String(hex[12..<16])+"-"+String(hex[16..<20])+"-"+String(hex[20..<32])
        let id = UUID(uuidString: uuidText)!
        let last = event.confirmations.last!.source
        let threshold = event.policy.thresholdsByType[event.entityType]!
        let calibration = event.frame.calibration!
        let payload = Payload(eventID: event.id,epochID: event.epochID,entityType: event.entityType,origin: origin.rawValue,
            ruleVersion: event.ruleVersion,coordinateFrameID: event.frame.id,upAxis: String(describing: event.frame.up),
            calibrationID: calibration.id,calibrationVersion: calibration.version,calibrationErrorMeters: calibration.maximumErrorMeters,
            policyID: event.policy.id,minimumDisplacementMeters: threshold.minimumDisplacementMeters,destinationToleranceMeters: threshold.destinationToleranceMeters,
            requiredConfirmations: threshold.confirmations,minimumDurationSeconds: threshold.minimumDurationSeconds,maximumGapSeconds: threshold.maximumGapSeconds,
            confirmedMinimumDisplacementMeters: event.minimumDisplacementMeters,baseline: Observation(event.baseline),confirmations: event.confirmations.map(Observation.init))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        return try WorldEventDraft(id: id,actorID: event.actorID,streamID: id,entityIDs: [event.entityID],type: "perception.movement_confirmed",
            times: JournalTimes(occurredAt: nil,observedAt: last.times.observedAt,timeZone: last.times.timeZone),
            sourceID: "movement:"+event.id,confidence: confidence,payloadVersion: 1,payload: encoder.encode(payload),correlationID: event.epochID)
    }
    private struct Payload: Encodable {
        let schemaVersion = "1", basis = "inferred", confidenceMeaning = "minimum_source_confidence"
        let eventID: String, epochID: UUID, entityType: String, origin: String, ruleVersion: String
        let coordinateFrameID: UUID, upAxis: String, calibrationID: UUID, calibrationVersion: String, calibrationErrorMeters: Double
        let policyID: UUID, minimumDisplacementMeters: Double, destinationToleranceMeters: Double
        let requiredConfirmations: Int, minimumDurationSeconds: Double, maximumGapSeconds: Double, confirmedMinimumDisplacementMeters: Double
        let baseline: Observation, confirmations: [Observation]
    }
    private struct Observation: Encodable {
        let observationID: UUID, cameraID: UUID, imageFrameID: UUID, modelID: String, modelVersion: String
        let occurredAt: Double?, observedAt: Double, recordedAt: Double, timeZone: String, confidence: Double?
        let validFrom: Double, validTo: Double?, lower: [Double], upper: [Double], maximumErrorMeters: Double
        init(_ observation: SpatialObservation) {
            let source = observation.source
            observationID = source.observationID; cameraID = source.cameraID; imageFrameID = source.imageFrameID
            modelID = source.modelID; modelVersion = source.modelVersion
            occurredAt = source.times.occurredAt?.secondsSince1970; observedAt = source.times.observedAt.secondsSince1970
            recordedAt = source.times.recordedAt.secondsSince1970; timeZone = source.times.timeZone.identifier; confidence = source.confidence?.value
            validFrom = observation.validity.from.secondsSince1970; validTo = observation.validity.to?.secondsSince1970
            guard case .calibrated3D(let box) = observation.geometry else { preconditionFailure("detector emits calibrated evidence only") }
            lower = box.lower; upper = box.upper; maximumErrorMeters = box.maximumErrorMeters
        }
    }
}
