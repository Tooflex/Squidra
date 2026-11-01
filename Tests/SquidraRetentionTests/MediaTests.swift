import Foundation
import PostgresNIO
import SquidraPostgres
import XCTest

// No shared test-instance mutable state. Every test owns actor identities.
final class MediaTests: XCTestCase, @unchecked Sendable {
    private func deadline() -> ContinuousClock.Instant { .now.advanced(by:.seconds(4)) }
    private func database(_ body: @escaping @Sendable (PostgresClient) async throws -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            XCTFail("Use T12-MEDIA with its actual isolated database"); return
        }
        let client = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() }; defer { group.cancelAll() }
            try await body(client)
        }
    }
    func testPolicyBounds() throws {
        XCTAssertEqual(try MediaRetentionPolicy().seconds,60)
        for seconds in [0,-1,3601,Int.max] { XCTAssertThrowsError(try MediaRetentionPolicy(seconds:seconds)) }
    }
    func testRoundTripExpiryPurgeAndIsolation() async throws {
        try await database { client in
            let actor = UUID(),frame = UUID(),other = UUID(),data = Data([0,1,255,0,42])
            let store = PostgresMediaRetention(actorID:actor,client:client),foreign = PostgresMediaRetention(actorID:other,client:client)
            let policy = try MediaRetentionPolicy(seconds:1)
            try await store.retain(frameID:frame,bytes:data,mediaType:"image/png",capturedMicroseconds:100,policy:policy,deadline:self.deadline())
            try await store.retain(frameID:frame,bytes:data,mediaType:"image/png",capturedMicroseconds:100,policy:policy,deadline:self.deadline())
            let loaded = try await store.load(frameID:frame,nowMicroseconds:1_000_099,deadline:self.deadline())
            XCTAssertEqual(loaded?.bytes,data); XCTAssertEqual(loaded?.state,.available)
            let hidden = try await foreign.load(frameID:frame,nowMicroseconds:100,deadline:self.deadline()); XCTAssertNil(hidden)
            let foreignPurge = try await foreign.purge(nowMicroseconds:2_000_000,deadline:self.deadline()); XCTAssertEqual(foreignPurge,0)
            let early = try await store.purge(nowMicroseconds:1_000_099,deadline:self.deadline()); XCTAssertEqual(early,0)
            let expired = try await store.load(frameID:frame,nowMicroseconds:1_000_100,deadline:self.deadline())
            XCTAssertEqual(expired?.state,.expired); XCTAssertNil(expired?.bytes)
            let purged = try await store.purge(nowMicroseconds:1_000_100,deadline:self.deadline()); XCTAssertEqual(purged,1)
            let repeated = try await store.purge(nowMicroseconds:1_000_100,deadline:self.deadline()); XCTAssertEqual(repeated,0)
            let rows = try await client.query("SELECT blob IS NULL,reason,byte_count FROM retained_media WHERE actor_id=\(actor) AND frame_id=\(frame)").collect()
            let (removed,reason,count) = try rows[0].decode((Bool,String,Int).self)
            XCTAssertTrue(removed);XCTAssertEqual(reason,"expired");XCTAssertEqual(count,5)
            do { try await store.retain(frameID:frame,bytes:data,mediaType:"image/png",capturedMicroseconds:100,policy:policy,deadline:self.deadline());XCTFail("Resurrection allowed") }
            catch MediaRetentionError.conflict {}
        }
    }
    func testErasureConflictsAndDatabaseGuards() async throws {
        try await database { client in
            let actor=UUID(),frame=UUID(),store=PostgresMediaRetention(actorID:actor,client:client),policy=try MediaRetentionPolicy()
            try await store.retain(frameID:frame,bytes:Data([1]),mediaType:"image/jpeg",capturedMicroseconds:100,policy:policy,deadline:self.deadline())
            do { try await store.retain(frameID:frame,bytes:Data([2]),mediaType:"image/jpeg",capturedMicroseconds:100,policy:policy,deadline:self.deadline());XCTFail("Conflicting retry accepted") }
            catch MediaRetentionError.conflict {}
            // Constraints forbid a null-reason pseudo-tombstone; rollback retains bytes.
            do { _ = try await client.query("UPDATE retained_media SET blob=NULL WHERE actor_id=\(actor)").collect();XCTFail("Invalid tombstone accepted") } catch is PSQLError {}
            let intact=try await store.load(frameID:frame,nowMicroseconds:100,deadline:self.deadline());XCTAssertEqual(intact?.bytes,Data([1]))
            let foreign=PostgresMediaRetention(actorID:UUID(),client:client)
            let foreignErase=try await foreign.erase(frameID:frame,nowMicroseconds:100,deadline:self.deadline());XCTAssertFalse(foreignErase)
            let erased=try await store.erase(frameID:frame,nowMicroseconds:100,deadline:self.deadline());XCTAssertTrue(erased)
            let again=try await store.erase(frameID:frame,nowMicroseconds:100,deadline:self.deadline());XCTAssertFalse(again)
            let value=try await store.load(frameID:frame,nowMicroseconds:100,deadline:self.deadline());XCTAssertEqual(value?.state,.erased);XCTAssertNil(value?.bytes)
            do { _ = try await client.query("DELETE FROM retained_media WHERE actor_id=\(actor)").collect();XCTFail("Reference removed") } catch is PSQLError {}
            do { _ = try await client.query("UPDATE retained_media SET blob=decode('01','hex'),reason=NULL,unavailable_us=NULL WHERE actor_id=\(actor)").collect();XCTFail("Blob resurrected") } catch is PSQLError {}
            do { _ = try await client.query("UPDATE retained_media SET expires_us=expires_us+1 WHERE actor_id=\(actor)").collect();XCTFail("Deadline changed") } catch is PSQLError {}
        }
    }
    func testCapacityAndRelease() async throws {
        try await database { client in
            let actor=UUID(),store=PostgresMediaRetention(actorID:actor,client:client),policy=try MediaRetentionPolicy(seconds:1)
            // Seed actual bounded rows in one query; exercise the adapter's capacity gate.
            _ = try await client.query("INSERT INTO retained_media(actor_id,frame_id,captured_us,expires_us,media_type,byte_count,blob) SELECT \(actor),gen_random_uuid(),0,1000000,'image/png',1,decode('01','hex') FROM generate_series(1,127)").collect()
            let admitted = try await withThrowingTaskGroup(of:Bool.self) { group in
                for _ in 0..<2 { group.addTask {
                    do { try await store.retain(frameID:UUID(),bytes:Data([1]),mediaType:"image/png",capturedMicroseconds:0,policy:policy,deadline:self.deadline()); return true }
                    catch MediaRetentionError.capacity { return false }
                } }
                var total=0
                for try await accepted in group { if accepted { total += 1 } }
                return total
            }
            XCTAssertEqual(admitted,1)
            do { try await store.retain(frameID:UUID(),bytes:Data([1]),mediaType:"image/png",capturedMicroseconds:0,policy:policy,deadline:self.deadline());XCTFail("Capacity exceeded") } catch MediaRetentionError.capacity {}
            let removed=try await store.purge(nowMicroseconds:1_000_000,deadline:self.deadline());XCTAssertEqual(removed,128)
            try await store.retain(frameID:UUID(),bytes:Data(repeating:1,count:65_536),mediaType:"image/png",capturedMicroseconds:1_000_000,policy:policy,deadline:self.deadline())
        }
    }
    func testInvalidInputAndDeadline() async throws {
        try await database { client in
            let store=PostgresMediaRetention(actorID:UUID(),client:client),policy=try MediaRetentionPolicy()
            for data in [Data(),Data(repeating:1,count:65_537)] {
                do { try await store.retain(frameID:UUID(),bytes:data,mediaType:"image/png",capturedMicroseconds:0,policy:policy,deadline:self.deadline());XCTFail("Invalid size") } catch MediaRetentionError.invalidRequest {}
            }
            let lateFrame=UUID()
            try await store.retain(frameID:lateFrame,bytes:Data([1]),mediaType:"image/png",capturedMicroseconds:253_402_296_000_000_000,policy:try MediaRetentionPolicy(seconds:3600),deadline:self.deadline())
            let latePurge=try await store.purge(nowMicroseconds:253_402_300_800_000_000,deadline:self.deadline());XCTAssertEqual(latePurge,1)
            do { _ = try await store.load(frameID:UUID(),nowMicroseconds:-1,deadline:self.deadline());XCTFail("Invalid time") } catch MediaRetentionError.invalidRequest {}
            do { _ = try await store.purge(nowMicroseconds:0,deadline:.now.advanced(by:.seconds(-1)));XCTFail("Expired deadline") } catch MediaRetentionError.unavailable {}
        }
    }
}
