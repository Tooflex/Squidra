import Foundation
import PostgresNIO
import SquidraDomain
import SquidraMeta
@testable import SquidraPostgres
import SquidraPerception
import XCTest

// SAFETY: stateless suite; state and concurrent updates live in isolated SQL.
final class AssociationSQLTests: XCTestCase, @unchecked Sendable {
    private static func frame(actor: UUID, camera: UUID, index: Int, frameID: UUID = UUID()) async throws -> ImportedFrame {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf:root.appendingPathComponent("fixtures/providers/vision-synthetic.v1.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        let frames = try XCTUnwrap(object["frames"] as? [[String:Any]])
        let image = try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(frames[index]["imageBase64"] as? String)))
        let time = 1_700_000_000.125 + Double(index)
        let context = try FrameContext(actorID:actor,cameraID:camera,frameID:frameID,
            timestamps:ObservationTimestamps(occurredAt:nil,observedAt:UTCInstant(secondsSince1970:time),recordedAt:UTCInstant(secondsSince1970:time+0.5),timeZone:IANATimeZone(identifier:"Europe/Paris")))
        return try await FrameImporter(model:SyntheticVisionModel(fixtureData:data)).ingest(bytes:image,mediaType:"image/png",context:context,
            consent:FrameImportConsent(actorID:actor,cameraID:camera,permitsLocalProcessing:true,permitsCloudTransfer:false,expiresAt:.now.advanced(by:.seconds(30))),deadline:.now.advanced(by:.seconds(3)))
    }
    private static func copy(_ state: EntityAssociationState, revision: Int64? = nil, frameID: UUID? = nil, tracks: [EntityTrack]? = nil) throws -> EntityAssociationState {
        let r = state.resolution, c = r.context
        let context = FrameContext(actorID:c.actorID,cameraID:c.cameraID,frameID:frameID ?? c.frameID,timestamps:c.timestamps)
        let resolution = try EntityResolution(context:context,identity:r.identity,imageSHA256:r.imageSHA256,assignments:r.assignments)
        return try EntityAssociationState(revision:revision ?? state.revision,policy:state.policy,width:state.width,height:state.height,inputDigest:state.inputDigest,resolution:resolution,tracks:tracks ?? state.tracks)
    }
    private static func expect(_ error: EntityAssociationError, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(error)") }
        catch let value as EntityAssociationError { XCTAssertEqual(value,error) }
        catch { XCTFail("Unredacted persistence failure") }
    }
    func testRealReloadContinuityCASRollbackCorruptionAndActorIsolation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let portText = env["SQUIDRA_TEST_DB_PORT"],let port = Int(portText),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            XCTFail("Run through isolated SQD-021-SQL helper");return
        }
        let config = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra")
        let client = config.makeClient(), second = config.makeClient()
        let actor = UUID(),camera = UUID(),foreign = UUID(),policy = try AssociationPolicy(maximumTracks:32)
        let store = PostgresEntityAssociationStore(client:client,actorID:actor,cameraID:camera)
        let reloadedStore = PostgresEntityAssociationStore(client:second,actorID:actor,cameraID:camera)
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };group.addTask { await second.run() };defer { group.cancelAll() }
            let initial = try await store.load(actorID:actor,cameraID:camera,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertNil(initial)
            let firstFrame = try await Self.frame(actor:actor,camera:camera,index:0)
            let resolver = ContinuityEntityResolver(store:store,policy:policy)
            let first = try await resolver.resolve(firstFrame,deadline:.now.advanced(by:.seconds(4)))
            let originalValue = try await store.load(actorID:actor,cameraID:camera,deadline:.now.advanced(by:.seconds(4)))
            let original = try XCTUnwrap(originalValue)
            let loaded = try await reloadedStore.load(actorID:actor,cameraID:camera,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(original,loaded); XCTAssertEqual(original.revision,1)
            let replay = try await ContinuityEntityResolver(store:reloadedStore,policy:policy).resolve(firstFrame,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(first,replay)
            let afterReplay = try await store.load(actorID:actor,cameraID:camera,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(afterReplay?.revision,1)
            let nextFrame = try await Self.frame(actor:actor,camera:camera,index:1)
            let next = try await ContinuityEntityResolver(store:reloadedStore,policy:policy).resolve(nextFrame,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(next.assignments.map(\.entityID),first.assignments.map(\.entityID))
            XCTAssertEqual(next.assignments.map(\.kind),[.matched,.matched]); XCTAssertTrue(next.synthetic)
            let stateValue = try await store.load(actorID:actor,cameraID:camera,deadline:.now.advanced(by:.seconds(4)))
            let state = try XCTUnwrap(stateValue)
            XCTAssertEqual(state.resolution.context,nextFrame.context); XCTAssertEqual(state.revision,2)
            let ids = state.tracks.map(\.entityID)
            let rows = try await client.query("SELECT count(*) FROM world_entities WHERE actor_id=\(actor) AND id=ANY(\(ids)::uuid[])").collect()
            XCTAssertEqual(try rows[0].decode(Int.self),2)
            await Self.expect(.invalidState) { _ = try await store.load(actorID:foreign,cameraID:camera,deadline:.now.advanced(by:.seconds(4))) }
            let foreignStore = PostgresEntityAssociationStore(client:client,actorID:foreign,cameraID:camera)
            let foreignState = try await foreignStore.load(actorID:foreign,cameraID:camera,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertNil(foreignState)
            await Self.expect(.invalidState) { try await foreignStore.compareAndSwap(state,expectedRevision:1,deadline:.now.advanced(by:.seconds(4))) }
            await Self.expect(.conflict) { try await store.compareAndSwap(Self.copy(original,revision:2),expectedRevision:1,deadline:.now.advanced(by:.seconds(4))) }
            // Concurrent compare-and-swap attempts from separate clients: exactly
            // one revision 3 wins; neither operation blindly retries.
            let a = try Self.copy(state,revision:3,frameID:UUID()), b = try Self.copy(state,revision:3,frameID:UUID())
            async let ra = Self.cas(store,a,expected:2)
            async let rb = Self.cas(reloadedStore,b,expected:2)
            let results = await [ra,rb]
            XCTAssertEqual(results.filter { $0 == nil }.count,1)
            XCTAssertEqual(results.filter { $0 == .conflict }.count,1)
            let winnerValue = try await store.load(actorID:actor,cameraID:camera,deadline:.now.advanced(by:.seconds(4)))
            let winner = try XCTUnwrap(winnerValue)
            XCTAssertTrue(winner == a || winner == b)
            // Inject a failure after candidate creation. No orphan entity or
            // cache revision may survive the failed transaction.
            let extraID = UUID(),extraTrack = try EntityTrack(entityID:extraID,lastSeen:state.resolution.context.timestamps.observedAt,box:PixelBox(x:0,y:0,width:1,height:1),appearance:[1,0])
            let attempted = try Self.copy(winner,revision:4,tracks:winner.tracks+[extraTrack])
            _ = try await client.query("CREATE FUNCTION reject_association_write() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture rejected update'; END $$").collect()
            _ = try await client.query("CREATE TRIGGER reject_association_write BEFORE UPDATE ON entity_associations FOR EACH ROW EXECUTE FUNCTION reject_association_write()").collect()
            await Self.expect(.unavailable) { try await store.compareAndSwap(attempted,expectedRevision:3,deadline:.now.advanced(by:.seconds(4))) }
            _ = try await client.query("DROP TRIGGER reject_association_write ON entity_associations").collect()
            _ = try await client.query("DROP FUNCTION reject_association_write()").collect()
            let orphan = try await client.query("SELECT count(*) FROM world_entities WHERE id=\(extraID)").collect()
            XCTAssertEqual(try orphan[0].decode(Int.self),0)
            let unchanged = try await store.load(actorID:actor,cameraID:camera,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(unchanged,winner)
            // A pre-existing foreign UUID collision must also roll back the
            // attempted cache update and any other newly inserted candidates.
            let foreignID = UUID(),otherID = UUID()
            _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(foreignID),\(foreign),'fixture')").collect()
            let collision = try [foreignID,otherID].map { try EntityTrack(entityID:$0,lastSeen:state.resolution.context.timestamps.observedAt,box:PixelBox(x:0,y:0,width:1,height:1),appearance:[1,0]) }
            let colliding = try Self.copy(winner,revision:4,tracks:winner.tracks+collision)
            await Self.expect(.invalidState) { try await store.compareAndSwap(colliding,expectedRevision:3,deadline:.now.advanced(by:.seconds(4))) }
            let rolledBack = try await client.query("SELECT count(*) FROM world_entities WHERE id=\(otherID)").collect()
            XCTAssertEqual(try rolledBack[0].decode(Int.self),0)
            // Closed codec rejects unknown fields, malformed vectors, bad
            // versions and lost precision; never accepts partial cache state.
            let encoded = try AssociationStateCodec.encode(winner)
            XCTAssertEqual(try AssociationStateCodec.decode(encoded),winner)
            var corrupt = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(encoded.utf8)) as? [String:Any])
            corrupt["unexpected"] = "private payload"
            let bad = String(decoding:try JSONSerialization.data(withJSONObject:corrupt),as:UTF8.self)
            _ = try await client.query("UPDATE entity_associations SET state=\(bad)::jsonb WHERE actor_id=\(actor) AND camera_id=\(camera)").collect()
            await Self.expect(.invalidState) { _ = try await store.load(actorID:actor,cameraID:camera,deadline:.now.advanced(by:.seconds(4))) }
            _ = try await client.query("UPDATE entity_associations SET state=\(encoded)::jsonb WHERE actor_id=\(actor) AND camera_id=\(camera)").collect()
            // A cache referring to a removed entity fails closed on load.
            _ = try await client.query("DELETE FROM world_entities WHERE id=\(ids[0])").collect()
            await Self.expect(.invalidState) { _ = try await store.load(actorID:actor,cameraID:camera,deadline:.now.advanced(by:.seconds(4))) }
        }
    }
    func testFullBoundedCodecProfilePreservesExactValuesAndRejectsCorruption() throws {
        let ids = (0..<32).map { _ in UUID() }, policy = try AssociationPolicy(maximumTracks:32)
        let observed = try UTCInstant(secondsSince1970:-0.125)
        let context = try FrameContext(actorID:UUID(),cameraID:UUID(),frameID:UUID(),timestamps:ObservationTimestamps(occurredAt:nil,observedAt:observed,recordedAt:UTCInstant(secondsSince1970:0.125),timeZone:IANATimeZone(identifier:"Europe/Paris")))
        let identity = try VisionIdentity(modelID:"fixture.association",version:"1.0.0",deployment:.synthetic)
        let tracks = try ids.map { id in try EntityTrack(entityID:id,lastSeen:observed,box:PixelBox(x:0,y:0,width:2,height:2),appearance:Array(repeating:0.123456789,count:256)) }
        let assignments = try ids.enumerated().map { index,id in
            try EntityAssignment(localID:"object-\(index)",entityID:id,kind:.newCandidate,candidates:ids.filter { $0 != id }.map { try AssociationCandidate(entityID:$0,score:0.125) })
        }
        let resolution = try EntityResolution(context:context,identity:identity,imageSHA256:String(repeating:"a",count:64),assignments:assignments)
        let state = try EntityAssociationState(revision:Int64.max,policy:policy,width:8,height:8,inputDigest:String(repeating:"b",count:64),resolution:resolution,tracks:tracks)
        let encoded = try AssociationStateCodec.encode(state)
        XCTAssertLessThan(encoded.utf8.count,AssociationStateCodec.maximumBytes)
        XCTAssertEqual(try AssociationStateCodec.decode(encoded),state)
        for key in ["schemaVersion","observed","unknown"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(encoded.utf8)) as? [String:Any])
            object[key] = key == "schemaVersion" ? 2 : "invalid"
            let text = String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self)
            XCTAssertThrowsError(try AssociationStateCodec.decode(text))
        }
        let unsupported = try EntityAssociationState(revision:1,policy:AssociationPolicy(maximumTracks:33),width:8,height:8,inputDigest:state.inputDigest,resolution:resolution,tracks:tracks)
        XCTAssertThrowsError(try AssociationStateCodec.encode(unsupported))
    }
    private static func cas(_ store: PostgresEntityAssociationStore, _ state: EntityAssociationState, expected: Int64) async -> EntityAssociationError? {
        do { try await store.compareAndSwap(state,expectedRevision:expected,deadline:.now.advanced(by:.seconds(4)));return nil }
        catch { return error as? EntityAssociationError ?? .unavailable }
    }
}
