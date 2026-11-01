import Foundation
import PostgresNIO
import SquidraDomain
import SquidraSpatial
import SquidraPerception
import SquidraPostgres
import SquidraWorld
import SquidraMemory

struct Manifest: Codable { let actor: UUID, watch: UUID, stage: String }
enum Failure: Error { case invalid }
@main struct WatchCrashFixture {
    static func main() async {
        do { try await run() } catch { print("WATCH_FIXTURE_FAILED");exit(1) }
    }
    static func run() async throws {
        let args = CommandLine.arguments,env = ProcessInfo.processInfo.environment
        guard args.count == 4,["seed","resume"].contains(args[1]),["pending","committed"].contains(args[2]),
              env["SQUIDRA_WATCH_CRASH_FIXTURE"] == "1",let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw Failure.invalid }
        let path = URL(fileURLWithPath: args[3])
        let client = try LocalDatabaseConfiguration(port: port,username: "squidra",password: password,database: "squidra").makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            let repository = PostgresWorldRepository(client: client)
            if args[1] == "seed" {
                let actor = UUID(),entity = UUID()
                _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect()
                let intentions = PostgresIntentionStore(actorID: actor,client: client)
                let watch = try await intentions.watch(entityID: entity,key: "crash-watch",deadline: .now.advanced(by: .seconds(4)))
                let recovery = MovementEpochRecovery(store: PostgresMovementEpochStore(client: client,actorID: actor),publisher: MovementPublisher(actorID: actor,repository: repository))
                for jitter in [true,false] {
                    let input = try report(actor: actor,entity: entity,jitter: jitter)
                    let policy = try MovementPolicy(id: UUID(),thresholdsByType: ["cup": MovementThreshold(minimumDisplacementMeters: 0.1)])
                    let epoch = try MovementEpoch(detector: ConfirmedMovementDetector(actorID: actor,entityID: entity,epochID: UUID(),entityType: "cup",policy: policy),samples: input.samples,origin: .synthetic)
                    let ids = try await recovery.submit(epoch,deadline: .now.advanced(by: .seconds(4)))
                    if jitter {
                        guard ids.isEmpty,try await intentions.processNext(deadline: .now.advanced(by: .seconds(4))) == false,
                              try await intentions.load(id: watch.id,deadline: .now.advanced(by: .seconds(4)))?.status == .active else { throw Failure.invalid }
                    } else { guard ids.count == 2 else { throw Failure.invalid } }
                }
                if args[2] == "committed" {
                    guard try await intentions.processNext(deadline: .now.advanced(by: .seconds(4))) else { throw Failure.invalid }
                }
                try JSONEncoder().encode(Manifest(actor: actor,watch: watch.id,stage: args[2])).write(to: path,options: .atomic)
                try await Task.sleep(for: .seconds(120))
                throw Failure.invalid
            } else {
                let manifest = try JSONDecoder().decode(Manifest.self,from: Data(contentsOf: path))
                guard manifest.stage == args[2] else { throw Failure.invalid }
                let store = PostgresIntentionStore(actorID: manifest.actor,client: client)
                let before = try await repository.page(actorID: manifest.actor,afterSequence: 0,cursor: nil,limit: 10,deadline: .now.advanced(by: .seconds(4)))
                guard before.events.count == (manifest.stage == "pending" ? 2 : 3) else { throw Failure.invalid }
                for _ in 0..<4 { if try await !store.processNext(deadline: .now.advanced(by: .seconds(4))) { break } }
                guard try await store.processNext(deadline: .now.advanced(by: .seconds(4))) == false,
                      try await store.load(id: manifest.watch,deadline: .now.advanced(by: .seconds(4)))?.status == .fulfilled else { throw Failure.invalid }
                let after = try await repository.page(actorID: manifest.actor,afterSequence: 0,cursor: nil,limit: 10,deadline: .now.advanced(by: .seconds(4)))
                let notifications = after.events.filter { $0.draft.type == "memory.watch_notified" }
                guard after.events.count == 3,notifications.count == 1,notifications[0].draft.causationID == after.events[0].draft.id else { throw Failure.invalid }
                if manifest.stage == "committed" { guard before.events == after.events else { throw Failure.invalid } }
                let duplicate = try await store.deliver(intentionID: manifest.watch,eventID: after.events[0].draft.id,deadline: .now.advanced(by: .seconds(4)))
                guard duplicate?.created == false,duplicate?.notificationEventID == notifications[0].draft.id else { throw Failure.invalid }
                let rows = try await client.query("SELECT count(*) FROM outbox WHERE actor_id=\(manifest.actor)").collect()
                guard try rows[0].decode(Int.self) == 0 else { throw Failure.invalid }
                print("CRASH_RECOVERY_VERIFIED")
            }
        }
    }
    static func report(actor: UUID, entity: UUID, jitter: Bool = false) throws -> MovementReport {
        let frame = try SpatialCoordinateFrame(actorID: actor,id: UUID(),up: .positiveZ,calibration: SpatialCalibration(id: UUID(),version: "fixture-1",maximumErrorMeters: 0))
        let camera = UUID()
        let samples = try (jitter ? [0.0,0.01,0.0,0.01,0.0,0.01,0.0] : [0.0,0.2,0.2,0.2,0.5,0.5,0.5]).enumerated().map { i,x in
            let time = try UTCInstant(secondsSince1970: 1_700_000_000+Double(i))
            let source = try SpatialSource(observationID: UUID(),cameraID: camera,imageFrameID: UUID(),modelID: "authored-scene",modelVersion: "1",
                times: ObservationTimestamps(occurredAt: nil,observedAt: time,recordedAt: time,timeZone: IANATimeZone(identifier: "Europe/Paris")),
                confidence: Confidence(0.8))
            return try MovementSample(observedAt: time,observation: SpatialObservation(actorID: actor,entityID: entity,coordinateFrameID: frame.id,
                geometry: .calibrated3D(SpatialBox3D(lower: [x,0,0],upper: [x+0.1,0.1,0.1],maximumErrorMeters: 0)),association: .confirmed,
                validity: SpatialValidity(from: time,to: nil),source: source),frame: frame)
        }
        return try ConfirmedMovementDetector(actorID: actor,entityID: entity,epochID: UUID(),entityType: "cup",
            policy: MovementPolicy(id: UUID(),thresholdsByType: ["cup": MovementThreshold(minimumDisplacementMeters: 0.1)])).evaluate(samples)
    }
}
