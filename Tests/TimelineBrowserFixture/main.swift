import Foundation
import PostgresNIO
import SquidraDomain
import SquidraPostgres
import SquidraWorld

private enum Failure: Error { case invalid }
private struct Manifest: Codable {
    let actor: UUID, subject: UUID, oldLocation: UUID, newLocation: UUID, original: UUID, correction: UUID
    let events: [UUID]
    let valid: String, from: String, to: String, early: String, late: String
}
private func run() async throws {
    let env = ProcessInfo.processInfo.environment, args = Array(CommandLine.arguments.dropFirst())
    guard env["SQUIDRA_BROWSER_FIXTURE"] == "1", args.count == 2, ["seed","verify"].contains(args[0]),
          let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init), let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw Failure.invalid }
    let path = URL(fileURLWithPath:args[1])
    let client = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
    let journal = PostgresWorldRepository(client:client)
    try await withThrowingTaskGroup(of:Void.self) { group in
        group.addTask { await client.run() }; defer { group.cancelAll() }
        if args[0] == "seed" {
            let actor = UUID(), subject = UUID(), frame = UUID(), stream = UUID(), locations = (0..<10).map { _ in UUID() }
            let projection = PostgresLocationProjection(actorID:actor,client:client)
            for entity in [subject] + locations { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect() }
            _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(frame),\(actor),'timeline',3,'metres')").collect()
            let start = try RFC3339.parse("2026-01-01T00:00:00Z")
            func instant(_ index: Int) throws -> UTCInstant { try UTCInstant(secondsSince1970:start.secondsSince1970 + Double(index)*3600) }
            func append(_ index: Int, location: UUID, corrects: UUID? = nil, expected: Int64) async throws -> JournalEvent {
                let change = try LocationFactChange(subjectID:subject,locationID:location,frameID:frame,valid:FactInterval(from:instant(index),to:instant(index+1)),basis:.observed,correctsEventID:corrects)
                let draft = try WorldEventDraft(actorID:actor,streamID:stream,entityIDs:[subject,location] + (corrects == nil ? [] : [locations[0]]),type:change.eventType,
                    times:JournalTimes(occurredAt:nil,observedAt:instant(index),timeZone:IANATimeZone(identifier:"Etc/UTC")),sourceID:"fixture:<script>window.compromised=true</script>",confidence:Confidence(0.9),payloadVersion:1,payload:change.encodedPayload(),causationID:corrects,correlationID:UUID())
                let event = try await journal.append(draft,expectedVersion:expected,idempotencyKey:"timeline-\(expected)",deadline:.now.advanced(by:.seconds(4))).event
                try await projection.apply(event); return event
            }
            var originals: [JournalEvent] = []
            for index in 0..<9 { originals.append(try await append(index,location:locations[index],expected:Int64(index))) }
            // Preserve a whole-second knowledge boundary usable by native UI controls.
            // recordedAt remains database-owned; do not forge journal timestamps.
            let earlySeconds = ceil(Double(originals.last!.recordedMicroseconds)/1_000_000)
            let delay = max(0, earlySeconds + 0.05 - Date().timeIntervalSince1970)
            guard delay < 2 else { throw Failure.invalid }
            try await Task.sleep(for:.seconds(delay))
            let correction = try await append(0,location:locations[9],corrects:originals[0].draft.id,expected:9)
            guard Double(correction.recordedMicroseconds)/1_000_000 > earlySeconds else { throw Failure.invalid }
            let manifest = try Manifest(actor:actor,subject:subject,oldLocation:locations[0],newLocation:locations[9],original:originals[0].draft.id,correction:correction.draft.id,
                events:originals.map(\.draft.id)+[correction.draft.id],valid:RFC3339.format(instant(0)),from:RFC3339.format(instant(0)),to:RFC3339.format(instant(9)),
                early:RFC3339.format(UTCInstant(secondsSince1970:earlySeconds)),late:RFC3339.format(UTCInstant(secondsSince1970:ceil(Double(correction.recordedMicroseconds)/1_000_000))))
            try JSONEncoder().encode(manifest).write(to:path,options:.atomic)
        } else {
            let m = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:path))
            let projection = PostgresLocationProjection(actorID:m.actor,client:client)
            for (known, location, event) in [(m.early,m.oldLocation,m.original),(m.late,m.newLocation,m.correction)] {
                let state = try await projection.state(actorID:m.actor,subjectID:m.subject,validAt:RFC3339.parse(m.valid),knownAt:RFC3339.parse(known),deadline:.now.advanced(by:.seconds(4)))
                guard state.facts.count == 1, state.facts[0].locationID == location, state.facts[0].sourceEventID == event else { throw Failure.invalid }
            }
            let rows = try await journal.page(actorID:m.actor,deadline:.now.advanced(by:.seconds(4)))
            guard rows.events.map(\.draft.id) == m.events else { throw Failure.invalid }
            let snapshot = try await client.query("SELECT row_to_json(e)::text FROM world_events e WHERE actor_id=\(m.actor) ORDER BY sequence").collect()
            let bytes = try JSONEncoder().encode(snapshot.map { try $0.decode(String.self) })
            let saved = path.appendingPathExtension("verified.json")
            if FileManager.default.fileExists(atPath:saved.path) { guard try Data(contentsOf:saved) == bytes else { throw Failure.invalid } }
            else { try bytes.write(to:saved,options:.atomic) }
        }
    }
}
do { try await run(); print("TIMELINE_BROWSER_FIXTURE_OK") }
catch { FileHandle.standardError.write(Data("Timeline browser fixture failed.\n".utf8)); exit(1) }
