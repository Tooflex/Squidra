import Foundation
import PostgresNIO
import SquidraDomain
import SquidraSpatial
import SquidraPerception
import SquidraPostgres
import SquidraWorld

struct Manifest: Codable { let actor: UUID, epoch: UUID, stage: String }
enum Failure: Error { case invalid }
struct CrashAfterCommit: WorldRepository {
    let base: any WorldRepository, manifest: Manifest, path: URL
    func append(_ event: WorldEventDraft, expectedVersion: Int64, idempotencyKey: String, deadline: ContinuousClock.Instant) async throws -> JournalAppend {
        _ = try await base.append(event,expectedVersion: expectedVersion,idempotencyKey: idempotencyKey,deadline: deadline)
        try JSONEncoder().encode(manifest).write(to: path,options: .atomic)
        try await Task.sleep(for: .seconds(120))
        throw Failure.invalid
    }
    func page(actorID: UUID, afterSequence: Int64, cursor: JournalCursor?, limit: Int, deadline: ContinuousClock.Instant) async throws -> JournalPage {
        try await base.page(actorID: actorID,afterSequence: afterSequence,cursor: cursor,limit: limit,deadline: deadline)
    }
}
@main struct MovementCrashFixture {
    static func main() async {
        do { try await run() } catch { print("MOVEMENT_FIXTURE_FAILED");exit(1) }
    }
    static func run() async throws {
        let args = CommandLine.arguments,env = ProcessInfo.processInfo.environment
        guard args.count == 4,["seed","resume"].contains(args[1]),["saved","published"].contains(args[2]),
              env["SQUIDRA_MOVEMENT_CRASH_FIXTURE"] == "1",let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw Failure.invalid }
        let path = URL(fileURLWithPath: args[3])
        let client = try LocalDatabaseConfiguration(port: port,username: "squidra",password: password,database: "squidra").makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            let repository = PostgresWorldRepository(client: client)
            if args[1] == "seed" {
                let actor = UUID(),entity = UUID(),input = try report(actor: actor,entity: entity),first = input.events[0]
                let epoch = try MovementEpoch(detector: ConfirmedMovementDetector(actorID: actor,entityID: entity,epochID: first.epochID,entityType: first.entityType,policy: first.policy),samples: input.samples,origin: .synthetic)
                _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect()
                let store = PostgresMovementEpochStore(client: client,actorID: actor),manifest = Manifest(actor: actor,epoch: first.epochID,stage: args[2])
                try await store.save(epoch,deadline: .now.advanced(by: .seconds(4)))
                if args[2] == "saved" {
                    try JSONEncoder().encode(manifest).write(to: path,options: .atomic)
                    try await Task.sleep(for: .seconds(120))
                } else {
                    _ = try await MovementEpochRecovery(store: store,publisher: MovementPublisher(actorID: actor,repository: CrashAfterCommit(base: repository,manifest: manifest,path: path))).recover(epochID: first.epochID,deadline: .now.advanced(by: .seconds(4)))
                }
                throw Failure.invalid
            } else {
                let manifest = try JSONDecoder().decode(Manifest.self,from: Data(contentsOf: path))
                guard manifest.stage == args[2] else { throw Failure.invalid }
                let store = PostgresMovementEpochStore(client: client,actorID: manifest.actor)
                guard let epoch = try await store.load(epochID: manifest.epoch,deadline: .now.advanced(by: .seconds(4))) else { throw Failure.invalid }
                let before = try await repository.page(actorID: manifest.actor,afterSequence: 0,cursor: nil,limit: 10,deadline: .now.advanced(by: .seconds(4)))
                guard before.events.count == (manifest.stage == "saved" ? 0 : 1) else { throw Failure.invalid }
                let expected = try epoch.evaluate().events.map(\.id)
                guard expected.count == 2 else { throw Failure.invalid }
                let recovery = MovementEpochRecovery(store: store,publisher: MovementPublisher(actorID: manifest.actor,repository: repository))
                let ids = try await recovery.recover(epochID: manifest.epoch,deadline: .now.advanced(by: .seconds(4)))
                let replay = try await recovery.recover(epochID: manifest.epoch,deadline: .now.advanced(by: .seconds(4)))
                guard ids == replay,Set(ids).count == 2 else { throw Failure.invalid }
                let after = try await repository.page(actorID: manifest.actor,afterSequence: 0,cursor: nil,limit: 10,deadline: .now.advanced(by: .seconds(4)))
                guard after.events.count == 2,after.events.map({ $0.draft.id }) == ids else { throw Failure.invalid }
                for (event,hash) in zip(after.events,expected) {
                    guard event.draft.type == "perception.movement_confirmed",event.draft.sourceID == "movement:"+hash,
                          event.draft.correlationID == manifest.epoch else { throw Failure.invalid }
                }
                if let committed = before.events.first { guard committed == after.events.first else { throw Failure.invalid } }
                print("CRASH_RECOVERY_VERIFIED")
            }
        }
    }
    static func report(actor: UUID, entity: UUID, unknownFinalConfidence: Bool = false) throws -> MovementReport {
        let frame = try SpatialCoordinateFrame(actorID: actor,id: UUID(),up: .positiveZ,calibration: SpatialCalibration(id: UUID(),version: "fixture-1",maximumErrorMeters: 0))
        let camera = UUID()
        let samples = try [0.0,0.2,0.2,0.2,0.5,0.5,0.5].enumerated().map { i,x in
            let time = try UTCInstant(secondsSince1970: 1_700_000_000+Double(i))
            let source = try SpatialSource(observationID: UUID(),cameraID: camera,imageFrameID: UUID(),modelID: "authored-scene",modelVersion: "1",
                times: ObservationTimestamps(occurredAt: nil,observedAt: time,recordedAt: time,timeZone: IANATimeZone(identifier: "Europe/Paris")),
                confidence: unknownFinalConfidence && i == 6 ? nil : Confidence(0.8))
            return try MovementSample(observedAt: time,observation: SpatialObservation(actorID: actor,entityID: entity,coordinateFrameID: frame.id,
                geometry: .calibrated3D(SpatialBox3D(lower: [x,0,0],upper: [x+0.1,0.1,0.1],maximumErrorMeters: 0)),association: .confirmed,
                validity: SpatialValidity(from: time,to: nil),source: source),frame: frame)
        }
        return try ConfirmedMovementDetector(actorID: actor,entityID: entity,epochID: UUID(),entityType: "cup",
            policy: MovementPolicy(id: UUID(),thresholdsByType: ["cup": MovementThreshold(minimumDisplacementMeters: 0.1)])).evaluate(samples)
    }
}
