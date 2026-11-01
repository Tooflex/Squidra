import Foundation
import PostgresNIO
import SquidraDomain
import SquidraWorld
import SquidraPostgres

struct Dataset: Decodable { let events: [Event], cases: [Query] }
struct Event: Decodable { let location: String, from: Double, to: Double?, corrects: Int?, inferred: Bool }
struct Query: Decodable { let id: String, valid: Double, known: Int }
struct Prediction: Encodable { let id: String, locations: [String], uncertainty: [String], sources: [Int] }
struct Output: Encodable { let predictions: [Prediction], databaseVersion: String }
enum Failure: Error { case invalid }
@main struct DatabaseEval {
    static func main() async {
        do { try await run() } catch { print("DATABASE_EVAL_FAILED");exit(1) }
    }
    static func run() async throws {
        let args = CommandLine.arguments,env = ProcessInfo.processInfo.environment
        guard args.count == 3,let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw Failure.invalid }
        let dataset = try JSONDecoder().decode(Dataset.self,from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let client = try LocalDatabaseConfiguration(port: port,username: "squidra",password: password,database: "squidra").makeClient()
        let actor = UUID(),subject = UUID(),frame = UUID(),stream = UUID()
        let places = Dictionary(uniqueKeysWithValues: Set(dataset.events.map(\.location)).map { ($0,UUID()) })
        let names = Dictionary(uniqueKeysWithValues: places.map { ($0.value,$0.key) })
        let base = 1_700_000_000.0
        func instant(_ offset: Double) throws -> UTCInstant { try UTCInstant(secondsSince1970: base+offset) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() }
            for id in [subject]+Array(places.values) { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(id),\(actor),'eval')").collect() }
            _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(frame),\(actor),'eval',3,'metres')").collect()
            let journal = PostgresWorldRepository(client: client),projection = PostgresLocationProjection(actorID: actor,client: client)
            var events: [JournalEvent] = []
            for (index,item) in dataset.events.enumerated() {
                let cause = item.corrects.map { events[$0].draft.id }
                let change = try LocationFactChange(subjectID: subject,locationID: places[item.location]!,frameID: frame,
                    valid: FactInterval(from: instant(item.from),to: item.to.map(instant)),basis: item.inferred ? .inferred : .observed,correctsEventID: cause)
                let draft = try WorldEventDraft(actorID: actor,streamID: stream,entityIDs: [subject,places[item.location]!]+(item.corrects.map { [places[dataset.events[$0].location]!] } ?? []),type: change.eventType,
                    times: JournalTimes(occurredAt: nil,observedAt: instant(item.from),timeZone: IANATimeZone(identifier: "Etc/UTC")),sourceID: "eval:event-\(index)",confidence: Confidence(0.8),payloadVersion: 1,payload: change.encodedPayload(),causationID: cause,correlationID: stream)
                let result = try await journal.append(draft,expectedVersion: Int64(index),idempotencyKey: "eval:\(index)",deadline: .now.advanced(by: .seconds(4)))
                events.append(result.event);try await projection.apply(result.event)
            }
            let sourceIndices = Dictionary(uniqueKeysWithValues: events.enumerated().map { ($0.element.draft.id,$0.offset) })
            var predictions: [Prediction] = []
            for row in dataset.cases {
                let known = row.known == -1 ? events[0].recordedMicroseconds-1 : events[row.known].recordedMicroseconds
                let snapshot = try await projection.state(actorID: actor,subjectID: subject,validAt: instant(row.valid),knownAt: UTCInstant(secondsSince1970: Double(known)/1_000_000),deadline: .now.advanced(by: .seconds(4)))
                predictions.append(Prediction(id: row.id,locations: snapshot.facts.map { names[$0.locationID]! }.sorted(),uncertainty: snapshot.uncertainty.map(\.rawValue).sorted(),sources: snapshot.facts.map { sourceIndices[$0.sourceEventID]! }.sorted()))
            }
            let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
            let versions = try await client.query("SHOW server_version").collect()
            let version = try versions[0].decode(String.self)
            try encoder.encode(Output(predictions: predictions,databaseVersion: version)).write(to: URL(fileURLWithPath: args[2]),options: .atomic)
        }
    }
}
