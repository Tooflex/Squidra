import Foundation
import PostgresNIO
import SquidraDomain
import SquidraPostgres
import SquidraWorld
import XCTest

private enum RestartFixtureError: Error { case missingEnvironment, invalidDescriptor, unexpectedData }
private struct RestartRequest: Codable, Sendable { let path: String, body: String }
private struct RestartEvent: Codable, Sendable { let id: UUID, sequence: Int64, recordedMicroseconds: Int64, recordedAt: String }
private struct RestartDescriptor: Codable, Sendable {
    let schemaVersion: String
    let actorId: UUID, subjectId: UUID, missingId: UUID, firstId: UUID, correctionId: UUID, originalLocationId: UUID, correctedLocationId: UUID
    let foreignActorId: UUID, foreignEventId: UUID
    let sourceEvents: [RestartEvent], foreignSequence: Int64
    let observedAt: String, correctionRecordedAt: String, firstRecordedAt: String
    let requests: [RestartRequest]
}

// SAFETY: stateless suite; every database and file belongs to the isolated helper.
final class RestartFixtureTests: XCTestCase, @unchecked Sendable {
    private static func path() throws -> URL {
        guard let value = ProcessInfo.processInfo.environment["SQUIDRA_RESTART_DESCRIPTOR_PATH"] else { throw RestartFixtureError.missingEnvironment }
        let url = URL(fileURLWithPath:value).resolvingSymlinksInPath()
        let temporaryRoot = URL(fileURLWithPath:NSTemporaryDirectory()).resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(temporaryRoot), url.deletingLastPathComponent().lastPathComponent.hasPrefix("squidra-restart-") else { throw RestartFixtureError.invalidDescriptor }
        return url
    }
    private static func descriptor() throws -> RestartDescriptor {
        let bytes = try Data(contentsOf:path())
        _ = try JSONDocument(bytes,maximumBytes:65_536)
        let descriptor = try JSONDecoder().decode(RestartDescriptor.self,from:bytes)
        guard descriptor.schemaVersion == "1", descriptor.sourceEvents.count == 3, descriptor.requests.count == 4 else { throw RestartFixtureError.invalidDescriptor }
        return descriptor
    }
    private static func database(_ body: @Sendable (PostgresClient) async throws -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["SQUIDRA_TEST_DB_PORT"], let port = Int(text), let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw RestartFixtureError.missingEnvironment }
        let client = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() }; defer { group.cancelAll() }
            try await body(client)
        }
    }
    private static func instant(_ micros: Int64) throws -> UTCInstant { try UTCInstant(secondsSince1970:Double(micros)/1_000_000) }
    private static func factCount(_ actor: UUID, client: PostgresClient) async throws -> Int64 {
        let rows = try await client.query("SELECT count(*)::bigint FROM spatial_facts WHERE actor_id=\(actor) AND predicate='located_at'").collect()
        guard let row = rows.first else { throw RestartFixtureError.unexpectedData }; return try row.decode(Int64.self)
    }
    private static func verifySources(_ descriptor: RestartDescriptor, client: PostgresClient) async throws {
        let page = try await PostgresWorldRepository(client:client).page(actorID:descriptor.actorId,afterSequence:0,cursor:nil,limit:128,deadline:.now.advanced(by:.seconds(4)))
        guard page.next == nil, page.events.map(\.draft.id) == descriptor.sourceEvents.map(\.id),
              page.events.map(\.sequence) == descriptor.sourceEvents.map(\.sequence),
              page.events.map(\.recordedMicroseconds) == descriptor.sourceEvents.map(\.recordedMicroseconds),
              page.events.allSatisfy({ $0.draft.sourceID == "fixture:restart" && $0.draft.actorID == descriptor.actorId }) else { throw RestartFixtureError.unexpectedData }
        let foreign = try await PostgresWorldRepository(client:client).page(actorID:descriptor.foreignActorId,afterSequence:0,cursor:nil,limit:128,deadline:.now.advanced(by:.seconds(4)))
        guard foreign.events.map(\.draft.id) == [descriptor.foreignEventId], foreign.throughSequence == descriptor.foreignSequence else { throw RestartFixtureError.unexpectedData }
        let other = try await factCount(descriptor.foreignActorId,client:client)
        guard other == 1 else { throw RestartFixtureError.unexpectedData }
    }
    func testSeedDurableJournalAndPrivateDescriptor() async throws {
        let path = try Self.path()
        try await Self.database { client in
            let countRows = try await client.query("SELECT count(*)::bigint FROM world_events").collect()
            guard let count = try countRows.first?.decode(Int64.self), count == 0 else { throw RestartFixtureError.unexpectedData }
            let actor = UUID(), subject = UUID(), missing = UUID(), a = UUID(), b = UUID(), d = UUID(), frame = UUID(), stream = UUID()
            let foreignActor = UUID(), foreignSubject = UUID(), foreignLocation = UUID(), foreignFrame = UUID()
            for (owner,entities) in [(actor,[subject,missing,a,b,d]),(foreignActor,[foreignSubject,foreignLocation])] {
                for entity in entities { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(owner),'fixture')").collect() }
            }
            for (owner,id) in [(actor,frame),(foreignActor,foreignFrame)] { _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(id),\(owner),'restart',3,'metres')").collect() }
            let repository = PostgresWorldRepository(client:client)
            let t0: Int64 = 1_700_000_000_000_000, t1 = t0+100_123_457, t2 = t0+200_000_000
            @Sendable func append(_ change: LocationFactChange, version: Int64, extra: [UUID] = []) async throws -> JournalEvent {
                let draft = try WorldEventDraft(actorID:actor,streamID:stream,entityIDs:[subject,change.locationID]+extra,type:change.eventType,
                    times:JournalTimes(occurredAt:nil,observedAt:Self.instant(t0),timeZone:IANATimeZone(identifier:"Europe/Paris")),
                    sourceID:"fixture:restart",confidence:Confidence(0.85),payloadVersion:1,payload:change.encodedPayload(),causationID:change.correctsEventID,correlationID:UUID())
                return try await repository.append(draft,expectedVersion:version,idempotencyKey:"restart-\(version)",deadline:.now.advanced(by:.seconds(4))).event
            }
            let first = try await append(LocationFactChange(subjectID:subject,locationID:a,frameID:frame,valid:FactInterval(fromMicroseconds:t0,toMicroseconds:t1),basis:.observed),version:0)
            let second = try await append(LocationFactChange(subjectID:subject,locationID:b,frameID:frame,valid:FactInterval(fromMicroseconds:t1,toMicroseconds:nil),basis:.observed),version:1)
            let correction = try await append(LocationFactChange(subjectID:subject,locationID:d,frameID:frame,valid:FactInterval(fromMicroseconds:t0,toMicroseconds:t1),basis:.observed,correctsEventID:first.draft.id),version:2,extra:[a])
            let foreignChange = try LocationFactChange(subjectID:foreignSubject,locationID:foreignLocation,frameID:foreignFrame,valid:FactInterval(fromMicroseconds:t0,toMicroseconds:nil),basis:.observed)
            let foreignDraft = try WorldEventDraft(actorID:foreignActor,streamID:UUID(),entityIDs:[foreignSubject,foreignLocation],type:foreignChange.eventType,
                times:JournalTimes(occurredAt:nil,observedAt:Self.instant(t0),timeZone:IANATimeZone(identifier:"Etc/UTC")),sourceID:"fixture:restart-foreign",
                confidence:Confidence(0.4),payloadVersion:1,payload:foreignChange.encodedPayload(),correlationID:UUID())
            let foreign = try await repository.append(foreignDraft,expectedVersion:0,idempotencyKey:"foreign",deadline:.now.advanced(by:.seconds(4))).event
            try await PostgresLocationProjection(actorID:foreignActor,client:client).apply(foreign)
            func body(_ object: [String:Any]) throws -> String { String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),as:UTF8.self) }
            func location(_ entity: UUID, known: UTCInstant) throws -> RestartRequest {
                try RestartRequest(path:"/api/v1/world/location",body:body(["schemaVersion":"1","entityId":entity.uuidString,
                    "validAt":RFC3339.format(Self.instant(t0+1_000_000)),"knownAt":RFC3339.format(known)]))
            }
            let requests = try [location(subject,known:correction.recordedAt),location(subject,known:second.recordedAt),
                RestartRequest(path:"/api/v1/world/changes",body:body(["schemaVersion":"1","subjectId":subject.uuidString,"from":RFC3339.format(Self.instant(t0)),
                    "to":RFC3339.format(Self.instant(t2)),"knownAt":RFC3339.format(correction.recordedAt),"limit":8])),location(missing,known:correction.recordedAt)]
            let descriptor = try RestartDescriptor(schemaVersion:"1",actorId:actor,subjectId:subject,missingId:missing,firstId:first.draft.id,correctionId:correction.draft.id,
                originalLocationId:a,correctedLocationId:d,foreignActorId:foreignActor,foreignEventId:foreign.draft.id,
                sourceEvents:[first,second,correction].map { try RestartEvent(id:$0.draft.id,sequence:$0.sequence,recordedMicroseconds:$0.recordedMicroseconds,recordedAt:RFC3339.format($0.recordedAt)) },foreignSequence:foreign.sequence,
                observedAt:RFC3339.format(Self.instant(t0)),correctionRecordedAt:RFC3339.format(correction.recordedAt),firstRecordedAt:RFC3339.format(first.recordedAt),requests:requests)
            let empty = try await Self.factCount(actor,client:client); XCTAssertEqual(empty,0)
            let checkpoint = try await PostgresLocationProjection(actorID:actor,client:client).checkpoint(); XCTAssertNil(checkpoint.lastSequence)
            try await Self.verifySources(descriptor,client:client)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
            try encoder.encode(descriptor).write(to:path,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        }
    }
    func testRemoveOnlyOwnedProjectionCacheAfterFirstProcessStops() async throws {
        let descriptor = try Self.descriptor()
        try await Self.database { client in
            try await Self.verifySources(descriptor,client:client)
            let before = try await Self.factCount(descriptor.actorId,client:client); XCTAssertEqual(before,3)
            _ = try await client.query("DELETE FROM spatial_facts WHERE actor_id=\(descriptor.actorId) AND predicate='located_at'").collect()
            _ = try await client.query("DELETE FROM projection_versions WHERE actor_id=\(descriptor.actorId) AND projection_name='world.locations'").collect()
            let cleared = try await Self.factCount(descriptor.actorId,client:client); XCTAssertEqual(cleared,0)
            let checkpoint = try await PostgresLocationProjection(actorID:descriptor.actorId,client:client).checkpoint(); XCTAssertNil(checkpoint.lastSequence)
            try await Self.verifySources(descriptor,client:client)
        }
    }
    func testVerifySecondProcessRebuiltSameFactsAndUntouchedSources() async throws {
        let descriptor = try Self.descriptor()
        try await Self.database { client in
            try await Self.verifySources(descriptor,client:client)
            let facts = try await Self.factCount(descriptor.actorId,client:client); XCTAssertEqual(facts,3)
            let checkpoint = try await PostgresLocationProjection(actorID:descriptor.actorId,client:client).checkpoint()
            XCTAssertEqual(checkpoint.lastSequence,descriptor.sourceEvents.last?.sequence)
            let other = try await PostgresLocationProjection(actorID:descriptor.foreignActorId,client:client).checkpoint()
            XCTAssertEqual(other.lastSequence,descriptor.foreignSequence)
        }
    }
}
