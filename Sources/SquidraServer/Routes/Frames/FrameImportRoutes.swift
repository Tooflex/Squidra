import Foundation
import Hummingbird
import SquidraDomain
import SquidraPerception
import SquidraPostgres

struct FrameImportRoutes: Sendable {
    let ingestion: PostgresFrameIngestion
    private struct Input: Decodable { let schemaVersion: String, imageBase64: String; let permitsLocalProcessing: Bool; let permitsCloudTransfer: Bool? }
    private var cloud: Bool { ingestion.policy.deployment == .cloud }
    private var maximumImageBytes: Int { cloud ? 65_536 : 524_288 }
    func mount(_ router: Router<BoundaryContext>) {
        router.get("/api/v1/frame-import-capabilities") { _,context in
            try context.requireActor(ingestion.policy.actorID)
            let data = try JSONSerialization.data(withJSONObject:["schemaVersion":"1","deployment":ingestion.policy.deployment.rawValue,
                "maximumImageBytes":maximumImageBytes,"requiresCloudTransferConsent":cloud])
            return Response(status:.ok,headers:[.contentType:"application/json"],body:.init(byteBuffer:.init(bytes:data)))
        }
        router.post("/api/v1/frames/import") { request,context in
            do {
                try context.requireActor(ingestion.policy.actorID)
                guard request.headers[values:.contentType].count == 1,
                      request.headers[.contentType]?.split(separator:";",maxSplits:1).first?.trimmingCharacters(in:.whitespaces).lowercased() == "application/json" else { throw HTTPError(.badRequest) }
                let body = try await request.body.collect(upTo:1_048_576)
                let data = Data(body.readableBytesView)
                _ = try JSONDocument(data,maximumBytes:1_048_576)
                guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],Set(object.keys) == Set(["schemaVersion","imageBase64","permitsLocalProcessing"] + (cloud ? ["permitsCloudTransfer"] : [])) else { throw HTTPError(.badRequest) }
                let input = try JSONDecoder().decode(Input.self,from:data)
                guard input.schemaVersion == "1" else { throw HTTPError(.badRequest) }
                guard input.permitsLocalProcessing,!cloud || input.permitsCloudTransfer == true else { throw HTTPError(.forbidden) }
                guard let bytes = Data(base64Encoded:input.imageBase64),bytes.count <= maximumImageBytes,bytes.base64EncodedString() == input.imageBase64 else { throw HTTPError(.badRequest) }
                // Receipt time is the observation time in this import profile.
                // No provider/client can choose actor, frame, camera or recordedAt.
                let now = try UTCInstant(secondsSince1970:Date().timeIntervalSince1970)
                let frame = FrameContext(actorID:ingestion.policy.actorID,cameraID:ingestion.policy.cameraID,frameID:UUID(),
                    timestamps:try ObservationTimestamps(occurredAt:nil,observedAt:now,recordedAt:now,timeZone:IANATimeZone(identifier:"Etc/UTC")))
                let deadline = ContinuousClock.now.advanced(by:.seconds(cloud ? 25 : 10))
                let consent = FrameImportConsent(actorID:frame.actorID,cameraID:frame.cameraID,permitsLocalProcessing:true,permitsCloudTransfer:cloud && input.permitsCloudTransfer == true,expiresAt:deadline)
                let receipt = try await ingestion.ingest(bytes:bytes,mediaType:"image/png",context:frame,consent:consent,deadline:deadline)
                let response = Result(deployment:receipt.resolution.identity.deployment.rawValue,frameId:frame.frameID,cameraId:frame.cameraID,locationId:ingestion.policy.locationID,coordinateFrameId:ingestion.policy.coordinateFrameID,
                    modelId:receipt.resolution.identity.modelID,modelVersion:receipt.resolution.identity.version,imageSHA256:receipt.resolution.imageSHA256,
                    observedAt:try RFC3339.format(now),knownAt:try RFC3339.format(UTCInstant(secondsSince1970:Double(receipt.locations.last!.recordedMicroseconds)/1_000_000)),
                    validityMilliseconds:ingestion.policy.validityMilliseconds,observationEventId:receipt.observation.draft.id,
                    entities:zip(receipt.resolution.assignments,receipt.locations).map { Entity(id:$0.entityID,localId:$0.localID,sourceEventId:$1.draft.id) })
                let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
                return try Response(status:.created,headers:[.contentType:"application/json"],body:.init(byteBuffer:.init(bytes:encoder.encode(response))))
            } catch { throw Self.mapped(error) }
        }
    }
    private struct Entity: Encodable { let id: UUID, localId: String, sourceEventId: UUID }
    private struct Result: Encodable {
        let schemaVersion = "1", basis = "inferred", mediaRetained = false
        let deployment: String
        let frameId: UUID, cameraId: UUID, locationId: UUID, coordinateFrameId: UUID
        let modelId: String, modelVersion: String, imageSHA256: String, observedAt: String, knownAt: String
        let validityMilliseconds: Int, observationEventId: UUID, entities: [Entity]
    }
    private static func mapped(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? any HTTPResponseError { return error }
        if error is DecodingError || error is JSONDocumentError { return HTTPError(.badRequest) }
        if let error = error as? VisionError {
            switch error {
            case .invalidMedia,.mediaTooLarge,.invalidDetection: return HTTPError(.badRequest)
            case .consentRequired: return HTTPError(.forbidden)
            case .timeout: return HTTPError(.gatewayTimeout)
            case .cancelled: return CancellationError()
            default: return HTTPError(.serviceUnavailable)
            }
        }
        return HTTPError(.serviceUnavailable)
    }
}
