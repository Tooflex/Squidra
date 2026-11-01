import Foundation
import PostgresNIO
import SquidraDomain
import SquidraPostgres
import SquidraWorld

private enum Failure: Error { case invalid }
private struct Manifest: Codable { let actor: UUID, camera: UUID, scene: UUID, coordinate: UUID }
private struct Receipt: Decodable {
    struct Entity: Decodable { let id: UUID, localId: String, sourceEventId: UUID }
    let schemaVersion: String, deployment: String, basis: String, mediaRetained: Bool
    let frameId: UUID, cameraId: UUID, locationId: UUID, coordinateFrameId: UUID, observationEventId: UUID
    let modelId: String, modelVersion: String, imageSHA256: String, observedAt: String, knownAt: String
    let validityMilliseconds: Int, entities: [Entity]
}
private func run() async throws {
    let env = ProcessInfo.processInfo.environment, args = Array(CommandLine.arguments.dropFirst())
    guard env["SQUIDRA_BROWSER_FIXTURE"] == "1", args.count == 2, ["seed","verify","verify-sam"].contains(args[0]),
          let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init), let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw Failure.invalid }
    let path = URL(fileURLWithPath:args[1])
    let client = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
    try await withThrowingTaskGroup(of:Void.self) { group in
        group.addTask { await client.run() }; defer { group.cancelAll() }
        if args[0] == "seed" {
            let m = Manifest(actor:UUID(),camera:UUID(),scene:UUID(),coordinate:UUID())
            // Trusted host configuration only. No observations or projections are seeded.
            _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(m.scene),\(m.actor),'fixture_scene')").collect()
            _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(m.coordinate),\(m.actor),'browser synthetic scene',3,'metres')").collect()
            try JSONEncoder().encode(m).write(to:path,options:.atomic)
        } else {
            let m = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:path))
            let r = try JSONDecoder().decode(Receipt.self,from:Data(contentsOf:path.appendingPathExtension("receipt.json")))
            let sam = args[0] == "verify-sam"
            let deployment = sam ? "cloud" : "synthetic"
            guard r.schemaVersion == "1",r.deployment == deployment,r.basis == "inferred",!r.mediaRetained,
                  r.cameraId == m.camera,r.locationId == m.scene,r.coordinateFrameId == m.coordinate,r.frameId == r.observationEventId,
                  r.modelId == (sam ? "meta.sam" : "fixture.vision"),r.modelVersion == (sam ? "alias:sam-3.1" : "1.0.0"),
                  r.imageSHA256 == (sam ? "62201c030c004452926e53f8f9c3659bfdcf22519812552c94aaa26e700993dc" : "41e0529cc7f8e5df0fd2a1d3e3265244739d50e9355aa5a0596db021d6835bb1"),
                  r.validityMilliseconds == 1000,r.entities.count == (sam ? 1 : 2),sam || Set(r.entities.map(\.localId)) == ["red","blue"] else { throw Failure.invalid }
            let observed = try RFC3339.parse(r.observedAt), known = try RFC3339.parse(r.knownAt)
            let micros = Int64((observed.secondsSince1970*1_000_000).rounded())
            let journal = PostgresWorldRepository(client:client), projection = PostgresLocationProjection(actorID:m.actor,client:client)
            let page = try await journal.page(actorID:m.actor,deadline:.now.advanced(by:.seconds(4)))
            guard page.next == nil, page.events.map(\.draft.id) == [r.observationEventId] + r.entities.map(\.sourceEventId),
                  let observation = page.events.first,let last = page.events.last,
                  observation.draft.type == "perception.frame_imported",try RFC3339.format(last.recordedAt) == r.knownAt else { throw Failure.invalid }
            let payload = try JSONSerialization.jsonObject(with:observation.draft.payload.bytes) as? [String:Any]
            guard payload?["imageSHA256"] as? String == r.imageSHA256,payload?["deployment"] as? String == deployment,
                  payload?["modelId"] as? String == r.modelId,payload?["modelVersion"] as? String == r.modelVersion,
                  payload?["imageBase64"] == nil,payload?["mask"] == nil else { throw Failure.invalid }
            let detections = payload?["detections"] as? [[String:Any]] ?? []
            let proof: [String:Any]?
            if sam {
                proof = try JSONSerialization.jsonObject(with:Data(contentsOf:path.appendingPathExtension("proof.json"))) as? [String:Any]
                guard detections.count == 1,payload?["width"] as? Int == 512,payload?["height"] as? Int == 512,
                      let detection = detections.first,detection["label"] as? String == "red square",
                      let x = detection["x"] as? Int,let y = detection["y"] as? Int,
                      let width = detection["width"] as? Int,let height = detection["height"] as? Int,
                      abs(x-128) <= 4,abs(y-128) <= 4,abs(width-256) <= 4,abs(height-256) <= 4 else { throw Failure.invalid }
            } else { proof = nil }
            for (entity,event) in zip(r.entities,page.events.dropFirst()) {
                guard event.draft.actorID == m.actor,event.draft.causationID == r.observationEventId,
                      event.draft.correlationID == r.frameId,event.draft.times.observedMicroseconds == micros else { throw Failure.invalid }
                let state = try await projection.state(actorID:m.actor,subjectID:entity.id,validAt:observed,knownAt:known,deadline:.now.advanced(by:.seconds(4)))
                guard state.facts.count == 1,state.uncertainty == [.inferredEvidence],state.projectedThroughSequence == state.availableThroughSequence else { throw Failure.invalid }
                let fact = state.facts[0]
                let confidence: Double
                if sam {
                    guard let detection = detections.first(where:{ ($0["entityId"] as? String)?.lowercased() == entity.id.uuidString.lowercased() }),
                          let score = detection["confidence"] as? Double,(0.5...1).contains(score),
                          proof?["confidence"] as? Double == score,
                          (proof?["id"] as? String)?.lowercased() == entity.sourceEventId.uuidString.lowercased(),
                          proof?["observedAt"] as? String == r.observedAt,proof?["recordedAt"] as? String == r.knownAt else { throw Failure.invalid }
                    confidence = score
                } else { confidence = 0.875 }
                guard fact.sourceEventID == entity.sourceEventId,fact.subjectID == entity.id,fact.locationID == m.scene,
                      fact.frameID == m.coordinate,fact.basis == .inferred,fact.confidence.value == confidence,
                      fact.sourceID == deployment + "-frame:" + r.imageSHA256,fact.valid.fromMicroseconds == micros,
                      fact.valid.toMicroseconds == micros + 1_000_000 else { throw Failure.invalid }
                let after = try await projection.state(actorID:m.actor,subjectID:entity.id,
                    validAt:UTCInstant(secondsSince1970:observed.secondsSince1970+1),knownAt:known,deadline:.now.advanced(by:.seconds(4)))
                guard after.facts.isEmpty,after.uncertainty == [.noEvidence] else { throw Failure.invalid }
            }
            let rows = try await client.query("SELECT row_to_json(e)::text FROM world_events e WHERE actor_id=\(m.actor) ORDER BY sequence").collect()
            let facts = try await client.query("SELECT row_to_json(f)::text FROM spatial_facts f WHERE actor_id=\(m.actor) ORDER BY id").collect()
            let associations = try await client.query("SELECT row_to_json(a)::text FROM entity_associations a WHERE actor_id=\(m.actor) ORDER BY camera_id").collect()
            let bytes = try JSONEncoder().encode([rows.map { try $0.decode(String.self) },facts.map { try $0.decode(String.self) },associations.map { try $0.decode(String.self) }])
            let snapshot = path.appendingPathExtension("verified.json")
            if FileManager.default.fileExists(atPath:snapshot.path) { guard try Data(contentsOf:snapshot) == bytes else { throw Failure.invalid } }
            else { try bytes.write(to:snapshot,options:.atomic) }
        }
    }
}
do { try await run(); print("FRAME_BROWSER_FIXTURE_OK") }
catch { FileHandle.standardError.write(Data("Frame browser fixture failed.\n".utf8)); exit(1) }
