import Foundation
import PostgresNIO
import SquidraDomain
import SquidraPostgres
import SquidraSecurity
import SquidraTools
import SquidraWorld
import XCTest

// SAFETY: stateless suite; all persistence belongs to the isolated SQL helper.
final class WorldToolsSQLTests: XCTestCase, @unchecked Sendable {
    private static func instant(_ value: Int64) throws -> UTCInstant { try UTCInstant(secondsSince1970:Double(value)/1_000_000) }
    private static func output(_ result: GatewayActionResult) throws -> [String:Any] {
        guard case .completed(let value) = result else { throw ToolError.invalidOutput }
        return try XCTUnwrap(JSONSerialization.jsonObject(with:value.payload) as? [String:Any])
    }
    func testRealGatewayReadsRetainEvidenceAcrossCorrectionAndContinuation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["SQUIDRA_TEST_DB_PORT"], let port = Int(text), let password = env["SQUIDRA_TEST_DB_PASSWORD"] else {
            XCTFail("Run through the isolated T13-READS database helper"); return
        }
        let client = try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
        let actor = UUID(), subject = UUID(), missing = UUID(), a = UUID(), b = UUID(), c = UUID(), d = UUID(), frame = UUID(), stream = UUID()
        let journal = PostgresWorldRepository(client:client), projection = PostgresLocationProjection(actorID:actor,client:client)
        let t0: Int64 = 1_700_000_000_000_000, t1 = t0+100_123_457, t2 = t0+200_000_000, t3 = t0+300_000_000
        let target = "entity:"+subject.uuidString.lowercased()
        let definitions = try [WorldLocationTool.definition(),WorldChangesTool.definition()]
        let registrations = try [WorldLocationTool(world:projection).registration(),WorldChangesTool(world:projection).registration()]
        @Sendable func gateway(_ owner: UUID) throws -> ActionGateway {
            let permissions = definitions.map { HostActionPermission(actorID:owner,tool:$0.id,capability:$0.capability,
                targets:[target,"entity:"+missing.uuidString.lowercased(),"world:changes"],scope:["world:read"],expiresAt:.now.advanced(by:.seconds(90))) }
            return try ActionGateway(tools:registrations,policy:HostActionPolicy(permissions:permissions))
        }
        @Sendable func invoke(_ definition: ToolDefinition, _ args: Data, owner: UUID = actor, target selectedTarget: String) async throws -> [String:Any] {
            let action = GatewayAction(actorID:owner,runID:UUID(),tool:definition.id,target:selectedTarget,arguments:args,
                scope:["world:read"],idempotencyKey:"read",deadline:.now.advanced(by:.seconds(5)))
            return try Self.output(await gateway(owner).invoke(action))
        }
        @Sendable func locationInput(_ known: Int64, entity: UUID = subject) throws -> Data {
            let fractional = String(try RFC3339.format(Self.instant(t1)).dropLast())+"123Z"
            return try JSONSerialization.data(withJSONObject:["schemaVersion":"1","entityId":entity.uuidString,"validAt":fractional,
                "knownAt":RFC3339.format(Self.instant(known))])
        }
        @Sendable func changeInput(_ known: Int64, cursor: String? = nil) throws -> Data {
            var args: [String:Any] = ["schemaVersion":"1","subjectId":subject.uuidString,"from":try RFC3339.format(Self.instant(t0)),
                "to":try RFC3339.format(Self.instant(t3)),"knownAt":try RFC3339.format(Self.instant(known)),"limit":1]
            if let cursor { args["cursor"] = cursor }
            return try JSONSerialization.data(withJSONObject:args)
        }
        @Sendable func append(_ change: LocationFactChange, expected: Int64, extra: [UUID] = []) async throws -> JournalEvent {
            let draft = try WorldEventDraft(actorID:actor,streamID:stream,entityIDs:[subject,change.locationID]+extra,type:change.eventType,
                times:JournalTimes(occurredAt:nil,observedAt:Self.instant(t0),timeZone:IANATimeZone(identifier:"Europe/Paris")),
                sourceID:"fixture:world-tools",confidence:Confidence(0.85),payloadVersion:1,payload:change.encodedPayload(),
                causationID:change.correctsEventID,correlationID:UUID())
            return try await journal.append(draft,expectedVersion:expected,idempotencyKey:"read-tools-\(expected)",deadline:.now.advanced(by:.seconds(4))).event
        }
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() }; defer { group.cancelAll() }
            for entity in [subject,missing,a,b,c,d] { _ = try await client.query("INSERT INTO world_entities(id,actor_id,kind) VALUES(\(entity),\(actor),'fixture')").collect() }
            _ = try await client.query("INSERT INTO coordinate_frames(id,actor_id,name,dimensions,units) VALUES(\(frame),\(actor),'world-tools',3,'metres')").collect()
            let first = try await append(LocationFactChange(subjectID:subject,locationID:a,frameID:frame,valid:FactInterval(fromMicroseconds:t0,toMicroseconds:t1),basis:.observed),expected:0)
            let second = try await append(LocationFactChange(subjectID:subject,locationID:b,frameID:frame,valid:FactInterval(fromMicroseconds:t1,toMicroseconds:t2),basis:.observed),expected:1)
            let third = try await append(LocationFactChange(subjectID:subject,locationID:c,frameID:frame,valid:FactInterval(fromMicroseconds:t2,toMicroseconds:nil),basis:.observed),expected:2)
            for event in [first,second,third] { try await projection.apply(event) }
            let corrected = try await append(LocationFactChange(subjectID:subject,locationID:d,frameID:frame,valid:FactInterval(fromMicroseconds:t1,toMicroseconds:t2),basis:.observed,correctsEventID:second.draft.id),expected:3,extra:[b])
            let known = corrected.recordedMicroseconds
            let before = try await invoke(definitions[0],locationInput(known),target:target)
            let beforeFacts = try XCTUnwrap(before["facts"] as? [[String:Any]])
            XCTAssertEqual(beforeFacts.first?["locationId"] as? String,b.uuidString.lowercased())
            XCTAssertEqual(beforeFacts.first?["confidence"] as? Double,0.85)
            XCTAssertEqual(beforeFacts.first?["timeZone"] as? String,"Europe/Paris")
            XCTAssertEqual(beforeFacts.first?["sourceEventId"] as? String,second.draft.id.uuidString.lowercased())
            XCTAssertTrue(beforeFacts.first?["occurredAt"] is NSNull)
            XCTAssertTrue((before["uncertainty"] as? [String] ?? []).contains("projectionBehind"))
            XCTAssertEqual(before["validAt"] as? String,try RFC3339.format(Self.instant(t1)))
            let page = try await invoke(definitions[1],changeInput(known),target:target)
            let cursor = try XCTUnwrap(page["next"] as? String)
            let cursorBytes = try XCTUnwrap(Data(base64Encoded:cursor))
            var future = try XCTUnwrap(JSONSerialization.jsonObject(with:cursorBytes) as? [String:Any])
            future["throughSequence"] = 1000; future["availableThroughSequence"] = 1000
            let forged = try JSONSerialization.data(withJSONObject:future).base64EncodedString()
            do { _ = try await invoke(definitions[1],changeInput(known,cursor:forged),target:target); XCTFail("Future watermark accepted") }
            catch { XCTAssertEqual(error as? ToolError,.invalidInput) }
            try await projection.apply(corrected)
            let current = try await invoke(definitions[0],locationInput(known),target:target)
            XCTAssertEqual((current["facts"] as? [[String:Any]])?.first?["locationId"] as? String,d.uuidString.lowercased())
            XCTAssertFalse((current["uncertainty"] as? [String] ?? []).contains("projectionBehind"))
            let historical = try await invoke(definitions[0],locationInput(third.recordedMicroseconds),target:target)
            XCTAssertEqual((historical["facts"] as? [[String:Any]])?.first?["locationId"] as? String,b.uuidString.lowercased())
            let continuation = try await invoke(definitions[1],changeInput(known,cursor:cursor),target:target)
            let oldChange = try XCTUnwrap((continuation["changes"] as? [[String:Any]])?.first)
            XCTAssertEqual(oldChange["id"] as? String,second.draft.id.uuidString.lowercased())
            XCTAssertEqual(continuation["projectedThroughSequence"] as? String,page["projectedThroughSequence"] as? String)
            let next = try XCTUnwrap(continuation["next"] as? String)
            let last = try await invoke(definitions[1],changeInput(known,cursor:next),target:target)
            let lastChange = try XCTUnwrap((last["changes"] as? [[String:Any]])?.first)
            XCTAssertEqual(lastChange["id"] as? String,third.draft.id.uuidString.lowercased())
            XCTAssertTrue((lastChange["supportingEventIds"] as? [String] ?? []).contains(second.draft.id.uuidString.lowercased()))
            let fresh = try await invoke(definitions[1],changeInput(known),target:target)
            let freshCursor = try XCTUnwrap(fresh["next"] as? String)
            let freshNext = try await invoke(definitions[1],changeInput(known,cursor:freshCursor),target:target)
            let correction = try XCTUnwrap((freshNext["changes"] as? [[String:Any]])?.first)
            XCTAssertEqual(correction["kind"] as? String,"correction")
            XCTAssertEqual(Set(correction["supportingEventIds"] as? [String] ?? []),[second.draft.id.uuidString.lowercased(),corrected.draft.id.uuidString.lowercased()])
            let noEvidence = try await invoke(definitions[0],locationInput(known,entity:missing),target:"entity:"+missing.uuidString.lowercased())
            XCTAssertEqual(noEvidence["status"] as? String,"no_evidence")
            let foreign = try await invoke(definitions[0],locationInput(known),owner:UUID(),target:target)
            XCTAssertEqual(foreign["status"] as? String,"not_found")
            XCTAssertEqual((foreign["facts"] as? [Any])?.count,0)
            XCTAssertTrue(foreign["projectedThroughSequence"] is NSNull)
            let denied = try ActionGateway(tools:registrations)
            do {
                _ = try await denied.invoke(GatewayAction(actorID:actor,runID:UUID(),tool:definitions[0].id,target:target,arguments:locationInput(known),
                    scope:["world:read"],idempotencyKey:"denied",deadline:.now.advanced(by:.seconds(2))))
                XCTFail("Unpermitted read succeeded")
            } catch { XCTAssertEqual(error as? ActionGatewayError,.denied) }
        }
    }
}
