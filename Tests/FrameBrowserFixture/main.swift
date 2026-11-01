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
    guard env["SQUIDRA_BROWSER_FIXTURE"] == "1", args.count == 2, ["seed","verify"].contains(args[0]),
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
            guard r.schemaVersion == "1",r.deployment == "synthetic",r.basis == "inferred",!r.mediaRetained,
                  r.cameraId == m.camera,r.locationId == m.scene,r.coordinateFrameId == m.coordinate,r.frameId == r.observationEventId,
                  r.modelId == "fixture.vision",r.modelVersion == "1.0.0",r.imageSHA256 == "41e0529cc7f8e5df0fd2a1d3e3265244739d50e9355aa5a0596db021d6835bb1",
                  r.validityMilliseconds == 1000,r.entities.count == 2,Set(r.entities.map(\.localId)) == ["red","blue"] else { throw Failure.invalid }
            let observed = try RFC3339.parse(r.observedAt), known = try RFC3339.parse(r.knownAt)
            let micros = Int64((observed.secondsSince1970*1_000_000).rounded())
            let journal = PostgresWorldRepository(client:client), projection = PostgresLocationProjection(actorID:m.actor,client:client)
            let page = try await journal.page(actorID:m.actor,deadline:.now.advanced(by:.seconds(4)))
            guard page.next == nil, page.events.map(\.draft.id) == [r.observationEventId] + r.entities.map(\.sourceEventId),
                  let observation = page.events.first,let last = page.events.last,
                  observation.draft.type == "perception.frame_imported",try RFC3339.format(last.recordedAt) == r.knownAt else { throw Failure.invalid }
            let payload = try JSONSerialization.jsonObject(with:observation.draft.payload.bytes) as? [String:Any]
            guard payload?["imageSHA256"] as? String == r.imageSHA256,payload?["deployment"] as? String == "synthetic",
                  payload?["imageBase64"] == nil,payload?["mask"] == nil else { throw Failure.invalid }
            for (entity,event) in zip(r.entities,page.events.dropFirst()) {
                guard event.draft.actorID == m.actor,event.draft.causationID == r.observationEventId,
                      event.draft.correlationID == r.frameId,event.draft.times.observedMicroseconds == micros else { throw Failure.invalid }
                let state = try await projection.state(actorID:m.actor,subjectID:entity.id,validAt:observed,knownAt:known,deadline:.now.advanced(by:.seconds(4)))
                guard state.facts.count == 1,state.uncertainty == [.inferredEvidence],state.projectedThroughSequence == state.availableThroughSequence else { throw Failure.invalid }
                let fact = state.facts[0]
                guard fact.sourceEventID == entity.sourceEventId,fact.subjectID == entity.id,fact.locationID == m.scene,
                      fact.frameID == m.coordinate,fact.basis == .inferred,fact.confidence.value == 0.875,
                      fact.sourceID == "synthetic-frame:" + r.imageSHA256,fact.valid.fromMicroseconds == micros,
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
