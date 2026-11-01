import Foundation
import PostgresNIO
import SquidraDomain
import SquidraMemory
import SquidraPerception
import SquidraSpatial
import SquidraPostgres
import SquidraWorld

struct Scenario: Codable {
    let schemaVersion: Int
    let origin, entity, monday, tuesday, wednesday, movement: String
    let initialLocation, tuesdayLocation, correctedMondayLocation: String
}
struct Identity: Codable {
    let actor, subject, desk, shelf, drawer, frame, stream, watch, epoch: UUID
    let events: [UUID]
}
enum Failure: Error { case invalid }
func instant(_ text: String) throws -> UTCInstant { try RFC3339.parse(text) }
func require(_ condition: Bool) throws { if !condition { throw Failure.invalid } }

@main struct DemoFixture {
    static func main() async {
        do { try await run() } catch { FileHandle.standardError.write(Data("Historical demo verification failed.\n".utf8));exit(1) }
    }
    static func run() async throws {
        let args=CommandLine.arguments,env=ProcessInfo.processInfo.environment
        guard args.count==5,["seed","verify","fake"].contains(args[1]),env["SQUIDRA_DEMO_FIXTURE"]=="1",
              let port=env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password=env["SQUIDRA_TEST_DB_PASSWORD"] else { throw Failure.invalid }
        let scenario=try JSONDecoder().decode(Scenario.self,from:Data(contentsOf:URL(fileURLWithPath:args[2])))
        try require(scenario.schemaVersion==1 && scenario.origin=="authored-synthetic-replay" && scenario.entity=="Arduino")
        let identityPath=URL(fileURLWithPath:args[3]),reportPath=URL(fileURLWithPath:args[4])
        let client=try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            let repository=PostgresWorldRepository(client:client)
            let identity: Identity
            if args[1]=="seed" {
                let actor=UUID(),subject=UUID(),desk=UUID(),shelf=UUID(),drawer=UUID(),frame=UUID(),stream=UUID()
                for entity in [subject,desk,shelf,drawer] {
                    _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'demo-fixture')").collect()
                }
                _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(frame),\(actor),'authored-demo',3,'metres')").collect()
                let first=UUID(),second=UUID(),correction=UUID()
                let monday=try FactInterval(from:instant(scenario.monday),to:instant(scenario.tuesday))
                let tuesday=try FactInterval(from:instant(scenario.tuesday),to:nil)
                let changes=[LocationFactChange(subjectID:subject,locationID:desk,frameID:frame,valid:monday,basis:.observed),
                             LocationFactChange(subjectID:subject,locationID:shelf,frameID:frame,valid:tuesday,basis:.observed),
                             LocationFactChange(subjectID:subject,locationID:drawer,frameID:frame,valid:monday,basis:.observed,correctsEventID:first)]
                let ids=[first,second,correction]
                // Historical INSERTs are authored replay data in a disposable DB.
                // Production append continues to own its real recording clock.
                for index in 0..<3 {
                    let change=changes[index],id=ids[index],version=Int64(index+1)
                    let at=try instant([scenario.monday,scenario.tuesday,scenario.wednesday][index]).secondsSince1970
                    let payload=String(decoding:try change.encodedPayload(),as:UTF8.self)
                    let correctionID: UUID?=index==2 ? first:nil
                    let entities=[subject,change.locationID]+(index==2 ? [desk]:[])
                    _ = try await client.query("""
                        INSERT INTO world_events(event_id,actor_id,stream_id,stream_version,idempotency_key,entity_ids,event_type,observed_at,recorded_at,source_id,confidence,payload_version,payload,causation_id,correlation_id)
                        VALUES(\(id),\(actor),\(stream),\(version),\("demo-\(index)"),\(entities),\(change.eventType),to_timestamp(\(at)),to_timestamp(\(at)),
                        'fixture:arduino-authored',0.8,1,jsonb_build_object('journalSchemaVersion','1','timeZone','Etc/UTC','data',\(payload)::jsonb),\(correctionID),\(stream))
                        """).collect()
                }
            let store=PostgresIntentionStore(actorID:actor,client:client)
                let watch=try await store.watch(entityID:subject,key:"arduino-once",deadline:.now.advanced(by:.seconds(4)))
                let epoch=try movement(actor:actor,subject:subject,at:instant(scenario.movement))
            let published=try await MovementEpochRecovery(store:PostgresMovementEpochStore(client:client,actorID:actor),publisher:MovementPublisher(actorID:actor,repository:repository)).submit(epoch,deadline:.now.advanced(by:.seconds(4)))
                try require(published.count==1)
                identity=Identity(actor:actor,subject:subject,desk:desk,shelf:shelf,drawer:drawer,frame:frame,stream:stream,watch:watch.id,epoch:epoch.detector.epochID,events:ids)
                try JSONEncoder().encode(identity).write(to:identityPath,options:.atomic)
            } else { identity=try JSONDecoder().decode(Identity.self,from:Data(contentsOf:identityPath)) }
            if args[1]=="verify" {
                let replay=try await MovementEpochRecovery(store:PostgresMovementEpochStore(client:client,actorID:identity.actor),publisher:MovementPublisher(actorID:identity.actor,repository:repository)).recover(epochID:identity.epoch,deadline:.now.advanced(by:.seconds(4)))
                try require(replay.count==1)
            }
            let store=PostgresIntentionStore(actorID:identity.actor,client:client)
            for _ in 0..<10 { if try await !store.processNext(deadline:.now.advanced(by:.seconds(4))) { break } }
            try require(try await store.processNext(deadline:.now.advanced(by:.seconds(4)))==false)
            let page=try await repository.page(actorID:identity.actor,limit:20,deadline:.now.advanced(by:.seconds(4)))
            let notifications=page.events.filter { $0.draft.type=="memory.watch_notified" }
            try require(notifications.count==1 && page.events.count==5)
            try require(try await store.load(id:identity.watch,deadline:.now.advanced(by:.seconds(4)))?.status == .fulfilled)
            let projection=PostgresLocationProjection(actorID:identity.actor,client:client)
            let checkpoint=try await projection.checkpoint()
            for event in page.events where event.sequence>(checkpoint.lastSequence ?? 0) { try await projection.apply(event) }
            let early=try await projection.state(actorID:identity.actor,subjectID:identity.subject,validAt:instant(scenario.monday),knownAt:instant(scenario.tuesday),deadline:.now.advanced(by:.seconds(4)))
            let late=try await projection.state(actorID:identity.actor,subjectID:identity.subject,validAt:instant(scenario.monday),knownAt:instant(scenario.wednesday),deadline:.now.advanced(by:.seconds(4)))
            let next=try await projection.state(actorID:identity.actor,subjectID:identity.subject,validAt:instant(scenario.tuesday),knownAt:instant(scenario.wednesday),deadline:.now.advanced(by:.seconds(4)))
            let unknown=try await projection.state(actorID:identity.actor,subjectID:identity.desk,validAt:instant(scenario.monday),knownAt:instant(scenario.wednesday),deadline:.now.advanced(by:.seconds(4)))
            try require(early.facts.map(\.locationID)==[identity.desk] && late.facts.map(\.locationID)==[identity.drawer] && next.facts.map(\.locationID)==[identity.shelf])
            try require(early.facts[0].sourceEventID==identity.events[0] && late.facts[0].sourceEventID==identity.events[2])
            try require(unknown.facts.isEmpty && unknown.uncertainty.contains(.noEvidence))
            do {
                _ = try await projection.state(actorID:UUID(),subjectID:identity.subject,validAt:instant(scenario.monday),knownAt:instant(scenario.wednesday),deadline:.now.advanced(by:.seconds(4)))
                throw Failure.invalid
            } catch WorldProjectionError.notFound { }
            func evidence(_ snapshot:WorldStateSnapshot, location:String) throws -> [String:Any] {
                let fact=snapshot.facts[0]
                return try ["location":location,"validAt":RFC3339.format(snapshot.validAt),"knowledgeTime":RFC3339.format(snapshot.knownAt),"sourceEventID":fact.sourceEventID.uuidString,"sourceID":fact.sourceID,"observedAt":RFC3339.format(fact.timestamps.observedAt),"recordedAt":RFC3339.format(fact.timestamps.recordedAt),"confidence":fact.confidence.value,"basis":fact.basis.rawValue]
            }
            let report:[String:Any]=["schemaVersion":1,"origin":scenario.origin,"modelMode":"none","realModelExecuted":false,"fakeModelExecuted":false,"entity":scenario.entity,"entityID":identity.subject.uuidString,"timeZone":"Etc/UTC","restartKind":"fresh fixture process; same isolated database","notificationDestination":"journal-only",
                "mondayEarly":try evidence(early,location:scenario.initialLocation),"mondayCorrected":try evidence(late,location:scenario.correctedMondayLocation),"tuesday":try evidence(next,location:scenario.tuesdayLocation),
                "unknown":"noEvidence","notificationCount":notifications.count,"notificationEventID":notifications[0].draft.id.uuidString,"eventIDs":page.events.map { $0.draft.id.uuidString }]
            let bytes=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted])
            if args[1] != "seed" { try require(try Data(contentsOf:reportPath)==bytes) }
            else { try bytes.write(to:reportPath,options:.atomic) }
            if args[1]=="fake" { try await fakeModelDemo(client:client,identity:identity,scenario:scenario,path:reportPath.deletingLastPathComponent().appendingPathComponent("fake-model.json")) }
            print("HISTORICAL_DEMO_VERIFIED")
        }
    }
    static func movement(actor:UUID,subject:UUID,at:UTCInstant) throws -> MovementEpoch {
        let frame=try SpatialCoordinateFrame(actorID:actor,id:UUID(),up:.positiveZ,calibration:SpatialCalibration(id:UUID(),version:"authored-demo-1",maximumErrorMeters:0))
        let camera=UUID()
        let samples=try [0.0,0.2,0.2,0.2].enumerated().map { i,x in
            let time=try UTCInstant(secondsSince1970:at.secondsSince1970+Double(i))
            let source=try SpatialSource(observationID:UUID(),cameraID:camera,imageFrameID:UUID(),modelID:"authored-demo",modelVersion:"1",times:ObservationTimestamps(occurredAt:nil,observedAt:time,recordedAt:time,timeZone:IANATimeZone(identifier:"Etc/UTC")),confidence:Confidence(0.8))
            return try MovementSample(observedAt:time,observation:SpatialObservation(actorID:actor,entityID:subject,coordinateFrameID:frame.id,geometry:.calibrated3D(SpatialBox3D(lower:[x,0,0],upper:[x+0.1,0.1,0.1],maximumErrorMeters:0)),association:.confirmed,validity:SpatialValidity(from:time,to:nil),source:source),frame:frame)
        }
        return try MovementEpoch(detector:ConfirmedMovementDetector(actorID:actor,entityID:subject,epochID:UUID(),entityType:"arduino",policy:MovementPolicy(id:UUID(),thresholdsByType:["arduino":MovementThreshold(minimumDisplacementMeters:0.1)])),samples:samples,origin:.synthetic)
    }
}
