import Foundation
import PostgresNIO
import SquidraPostgres
import XCTest

final class ExportTests: XCTestCase, @unchecked Sendable {
    private let canary="PRIVATE_CANARY_NOT_FOR_EXPORT_4927"
    private func deadline() -> ContinuousClock.Instant { .now.advanced(by:.seconds(4)) }
    private func database(_ body: @escaping @Sendable (PostgresClient) async throws -> Void) async throws {
        let env=ProcessInfo.processInfo.environment
        guard let port=env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password=env["SQUIDRA_TEST_DB_PASSWORD"] else { XCTFail("Use the real T12-EXPORT harness");return }
        let client=try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };defer { group.cancelAll() };try await body(client)
        }
    }
    private func seed(_ client:PostgresClient,actor:UUID,count:Int) async throws -> (UUID,UUID,UUID) {
        let entity=UUID(),frame=UUID(),stream=UUID()
        _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind,label) VALUES(\(entity),\(actor),\(canary),\(canary))").collect()
        _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units,metadata) VALUES(\(frame),\(actor),\(canary),3,'metres',jsonb_build_object('secret',\(canary)::text))").collect()
        _ = try await client.query("""
            INSERT INTO world_events(event_id,actor_id,stream_id,stream_version,idempotency_key,entity_ids,event_type,observed_at,source_id,confidence,payload_version,payload,correlation_id)
            SELECT gen_random_uuid(),\(actor),\(stream),n,n::text,ARRAY[\(entity)::uuid],\(canary),to_timestamp(1.25),\(canary),0.8,1,jsonb_build_object('secret',\(canary)::text),gen_random_uuid() FROM generate_series(1,\(count)) n
            """).collect()
        let rows=try await client.query("SELECT event_id FROM world_events WHERE actor_id=\(actor) ORDER BY sequence LIMIT 1").collect()
        let event=try rows[0].decode(UUID.self)
        _ = try await client.query("""
            INSERT INTO spatial_facts(id,actor_id,subject_id,predicate,object_id,frame_id,valid_from,confidence,provenance_event_id)
            VALUES(gen_random_uuid(),\(actor),\(entity),\(canary),\(entity),\(frame),to_timestamp(1.25),0.8,\(event))
            """).collect()
        return(entity,frame,event)
    }
    func testActorIsolationSecretCanariesAndNoMutation() async throws {
        try await database { client in
            let actor=UUID(),foreign=UUID()
            let own=try await self.seed(client,actor:actor,count:2),other=try await self.seed(client,actor:foreign,count:2)
            let before=try await client.query("SELECT md5(string_agg(row_to_json(e)::text,'' ORDER BY sequence)) FROM world_events e WHERE actor_id=\(actor)").collect()[0].decode(String.self)
            let page=try await PostgresStructuralExport(actorID:actor,client:client).page(deadline:self.deadline())
            XCTAssertEqual(page.events.count,2);XCTAssertEqual(page.facts.count,1);XCTAssertEqual(page.facts[0].subjectID,own.0)
            XCTAssertEqual(page.events[0].observedMicroseconds,1_250_000)
            let encoded=String(decoding:try JSONEncoder().encode(page),as:UTF8.self).lowercased()
            XCTAssertFalse(encoded.contains(self.canary.lowercased()))
            for id in [foreign,other.0,other.1,other.2] { XCTAssertFalse(encoded.contains(id.uuidString.lowercased())) }
            for key in ["payload\"", "sourceid", "label\"", "blob\""] { XCTAssertFalse(encoded.contains(key)) }
            let after=try await client.query("SELECT md5(string_agg(row_to_json(e)::text,'' ORDER BY sequence)) FROM world_events e WHERE actor_id=\(actor)").collect()[0].decode(String.self)
            XCTAssertEqual(before,after)
        }
    }
    func testPaginationHighWaterExcludesLaterEvents() async throws {
        try await database { client in
            let actor=UUID();_ = try await self.seed(client,actor:actor,count:3)
            let exporter=PostgresStructuralExport(actorID:actor,client:client)
            let first=try await exporter.page(limit:1,deadline:self.deadline())
            _ = try await self.seed(client,actor:actor,count:1)
            let second=try await exporter.page(cursor:XCTUnwrap(first.next),limit:1,deadline:self.deadline())
            let third=try await exporter.page(cursor:XCTUnwrap(second.next),limit:1,deadline:self.deadline())
            XCTAssertNil(third.next);XCTAssertEqual(first.highWater,third.highWater)
            XCTAssertLessThan(first.events[0].sequence,second.events[0].sequence);XCTAssertLessThan(second.events[0].sequence,third.events[0].sequence)
            let fresh=try await exporter.page(deadline:self.deadline());XCTAssertEqual(fresh.events.count,4)
        }
    }
    func testCursorLimitAndDeadlineValidation() async throws {
        try await database { client in
            let actor=UUID(),exporter=PostgresStructuralExport(actorID:actor,client:client)
            for limit in [0,65,Int.max] {
                do { _ = try await exporter.page(limit:limit,deadline:self.deadline());XCTFail("Invalid limit") } catch StructuralExportError.invalidLimit {}
            }
            let wrong=try StructuralExportCursor(actorID:UUID(),afterSequence:0,highWater:1)
            do { _ = try await exporter.page(cursor:wrong,deadline:self.deadline());XCTFail("Foreign cursor") } catch StructuralExportError.invalidCursor {}
            let malformed=try JSONDecoder().decode(StructuralExportCursor.self,from:Data("{\"actorID\":\"\(actor.uuidString)\",\"afterSequence\":-1,\"highWater\":0}".utf8))
            do { _ = try await exporter.page(cursor:malformed,deadline:self.deadline());XCTFail("Decoded invalid cursor") } catch StructuralExportError.invalidCursor {}
            do { _ = try await exporter.page(deadline:.now.advanced(by:.seconds(-1)));XCTFail("Expired deadline") } catch StructuralExportError.unavailable {}
        }
    }
    func testExcessAssociatedFactsFailWithoutPartialExport() async throws {
        try await database { client in
            let actor=UUID(),ids=try await self.seed(client,actor:actor,count:1)
            _ = try await client.query("""
                INSERT INTO spatial_facts(id,actor_id,subject_id,predicate,object_id,frame_id,valid_from,confidence,provenance_event_id)
                SELECT gen_random_uuid(),\(actor),\(ids.0),'located_at',\(ids.0),\(ids.1),to_timestamp(1.25),0.8,\(ids.2) FROM generate_series(1,128)
                """).collect()
            do { _ = try await PostgresStructuralExport(actorID:actor,client:client).page(deadline:self.deadline());XCTFail("Truncated export accepted") } catch StructuralExportError.unavailable {}
            let count=try await client.query("SELECT count(*)::bigint FROM spatial_facts WHERE actor_id=\(actor)").collect()[0].decode(Int64.self)
            XCTAssertEqual(count,129)
        }
    }
    func testEmptyAndMaximumPage() async throws {
        try await database { client in
            let actor=UUID(),exporter=PostgresStructuralExport(actorID:actor,client:client)
            let empty=try await exporter.page(deadline:self.deadline());XCTAssertTrue(empty.events.isEmpty);XCTAssertNil(empty.next);XCTAssertEqual(empty.highWater,0)
            _ = try await self.seed(client,actor:actor,count:65)
            let first=try await exporter.page(limit:64,deadline:self.deadline());XCTAssertEqual(first.events.count,64)
            let last=try await exporter.page(cursor:XCTUnwrap(first.next),limit:64,deadline:self.deadline());XCTAssertEqual(last.events.count,1);XCTAssertNil(last.next)
            XCTAssertEqual(Set((first.events+last.events).map(\.id)).count,65)
        }
    }
}
