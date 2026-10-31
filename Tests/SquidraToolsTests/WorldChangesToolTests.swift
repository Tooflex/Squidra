import Foundation
import SquidraDomain
import SquidraSecurity
import SquidraTools
import SquidraWorld
import XCTest

private actor ChangesQueryFixture: WorldChangesQuerying {
    enum Mode: Sendable { case normal, correction, empty, wrongActor, wrongSubject, reversedOrder, tooMany, badNext, excessiveEvidence, badPrior }
    let mode: Mode
    private(set) var calls = 0
    private(set) var lastActor: UUID?
    init(_ mode: Mode = .normal) { self.mode = mode }
    static let subject = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static func uuid(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d",value))! }
    func changes(_ query: WorldChangesQuery, cursor: WorldChangesCursor?, limit: Int, deadline: ContinuousClock.Instant) throws -> WorldChangesPage {
        calls += 1; lastActor = query.actorID
        if let cursor, cursor.throughSequence != 10 || cursor.availableThroughSequence != 10 { throw WorldChangesError.invalidCursor }
        if mode == .empty { return WorldChangesPage(changes: [], next: nil, throughSequence: 10, availableThroughSequence: 10) }
        let actor = mode == .wrongActor ? UUID() : query.actorID
        let subject = mode == .wrongSubject ? UUID() : Self.subject
        func fact(_ id: Int, from: Double, to: Double?, recorded: Double = 10, closed: Double? = nil, inferred: Bool = false) throws -> WorldLocationFact {
            let recordedAt = try UTCInstant(secondsSince1970: recorded)
            return try WorldLocationFact(id: Self.uuid(id), actorID: actor, subjectID: subject, locationID: Self.uuid(100+id), frameID: Self.uuid(9),
                valid: FactInterval(from: UTCInstant(secondsSince1970: from), to: to.map { try UTCInstant(secondsSince1970:$0) }),
                transaction: FactInterval(from: recordedAt, to: closed.map { try UTCInstant(secondsSince1970:$0) }),
                confidence: Confidence(0.6), basis: inferred ? .inferred : .observed, sourceID: "fixture:source", sourceEventID: Self.uuid(id),
                timestamps: ObservationTimestamps(occurredAt: nil, observedAt: UTCInstant(secondsSince1970: from), recordedAt: recordedAt, timeZone: IANATimeZone(identifier:"Etc/UTC")))
        }
        let old = try fact(3,from:0,to: mode == .badPrior ? 19 : 20)
        let middle = try fact(4,from:20,to:40), newest = try fact(5,from:40,to:nil)
        let first = try WorldChange(current:middle,previous:[old],isCorrection:false,conflictingCurrent:false,projectionBehind:false)
        let second = try WorldChange(current:newest,previous:[middle],isCorrection:false,conflictingCurrent:false,projectionBehind:false)
        if mode == .correction {
            let prior = try fact(6,from:20,to:40,closed:50)
            let corrected = try fact(7,from:20,to:40,recorded:50,inferred:true)
            let change = try WorldChange(current:corrected,previous:[prior],isCorrection:true,conflictingCurrent:false,projectionBehind:false)
            return WorldChangesPage(changes:[change],next:nil,throughSequence:10,availableThroughSequence:10)
        }
        if mode == .excessiveEvidence {
            let priors = try (100..<132).map { try fact($0,from:0,to:20) }
            let change = try WorldChange(current:middle,previous:priors,isCorrection:false,conflictingCurrent:false,projectionBehind:false)
            return WorldChangesPage(changes:[change],next:nil,throughSequence:10,availableThroughSequence:10)
        }
        if mode == .reversedOrder || mode == .tooMany {
            return WorldChangesPage(changes: mode == .reversedOrder ? [second,first] : [first,second],next:nil,throughSequence:10,availableThroughSequence:10)
        }
        if cursor != nil { return WorldChangesPage(changes:[second],next:nil,throughSequence:10,availableThroughSequence:10) }
        let next = try WorldChangesCursor(query:query,throughSequence:10,availableThroughSequence:10,
            afterValidMicroseconds: mode == .badNext ? 21_000_000 : 20_000_000,afterFactID:middle.id)
        return WorldChangesPage(changes:[first],next:next,throughSequence:10,availableThroughSequence:10)
    }
}

// SAFETY: stateless suite; mutable query observations are isolated by an actor.
final class WorldChangesToolTests: XCTestCase, @unchecked Sendable {
    private static let actor = UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
    private static func input(_ changes: [String:Any] = [:]) throws -> Data {
        var value: [String:Any] = ["schemaVersion":"1","from":"1970-01-01T00:00:00Z","to":"1970-01-01T00:01:40Z",
            "knownAt":"1970-01-01T00:03:20Z","limit":1]
        value.merge(changes) { _,new in new }; return try JSONSerialization.data(withJSONObject:value)
    }
    private static func action(input: Data? = nil, actor: UUID = actor, target: String = "world:changes", scope: Set<String> = ["world:read"]) throws -> GatewayAction {
        try GatewayAction(actorID:actor,runID:UUID(),tool:WorldChangesTool.definition().id,target:target,arguments:input ?? Self.input(),
            scope:scope,idempotencyKey:"changes-read",deadline:.now.advanced(by:.seconds(3)))
    }
    private static func gateway(_ fixture: ChangesQueryFixture, actor: UUID = actor, deny: Bool = false) throws -> ActionGateway {
        let definition = try WorldChangesTool.definition()
        let policy: any PolicyEngine = deny ? DenyAllActionPolicy() : HostActionPolicy(permissions:[HostActionPermission(actorID:actor,
            tool:definition.id,capability:definition.capability,targets:["world:changes","entity:"+ChangesQueryFixture.subject.uuidString.lowercased()],
            scope:["world:read"],expiresAt:.now.advanced(by:.seconds(10)))])
        return try ActionGateway(tools:[WorldChangesTool(world:fixture).registration()],policy:policy)
    }
    private static func output(_ result: GatewayActionResult) throws -> [String:Any] {
        guard case .completed(let value) = result else { throw ToolError.invalidOutput }
        return try XCTUnwrap(JSONSerialization.jsonObject(with:value.payload) as? [String:Any])
    }
    func testEmbeddedSchemasMatchRepositoryAndCompile() throws {
        let definition = try WorldChangesTool.definition()
        _ = try ToolCatalog(definitions:[definition])
        XCTAssertEqual(definition.risk,.r0); XCTAssertEqual(definition.idempotency,.readOnly)
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (side,bytes) in [("input",definition.inputSchema),("output",definition.outputSchema)] {
            let file = root.appendingPathComponent("Schemas/tools/world/world.get_changes.1.0.0.\(side).json")
            XCTAssertEqual(try JSONSerialization.jsonObject(with:bytes) as? NSDictionary,
                           try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? NSDictionary)
        }
    }
    func testTwoPagesRetainSupportingFactsAndExactContinuation() async throws {
        let fixture = ChangesQueryFixture(), gateway = try Self.gateway(fixture)
        let first = try Self.output(await gateway.invoke(Self.action()))
        let cursor = try XCTUnwrap(first["next"] as? String)
        let second = try Self.output(await gateway.invoke(Self.action(input:Self.input(["cursor":cursor]))))
        let a = try XCTUnwrap((first["changes"] as? [[String:Any]])?.first)
        let b = try XCTUnwrap((second["changes"] as? [[String:Any]])?.first)
        XCTAssertNotEqual(a["id"] as? String,b["id"] as? String)
        XCTAssertEqual(a["kind"] as? String,"location_changed")
        XCTAssertEqual(a["effectiveAt"] as? String,"1970-01-01T00:00:20.000000Z")
        XCTAssertEqual((a["supportingEventIds"] as? [String])?.count,2)
        XCTAssertEqual((first["facts"] as? [Any])?.count,2)
        XCTAssertEqual((second["facts"] as? [Any])?.count,2)
        XCTAssertTrue(second["next"] is NSNull)
        let count = await fixture.calls; XCTAssertEqual(count,2)
        let actor = await fixture.lastActor; XCTAssertEqual(actor,Self.actor)
    }
    func testCorrectionPreservesReplacedEvidenceAndInference() async throws {
        let output = try Self.output(await Self.gateway(ChangesQueryFixture(.correction)).invoke(Self.action()))
        let change = try XCTUnwrap((output["changes"] as? [[String:Any]])?.first)
        XCTAssertEqual(change["kind"] as? String,"correction")
        XCTAssertEqual(change["uncertainty"] as? [String],["inferredEvidence"])
        XCTAssertEqual((output["facts"] as? [Any])?.count,2)
    }
    func testEmptyPageIsCompleteDataWithoutInventedChanges() async throws {
        let output = try Self.output(await Self.gateway(ChangesQueryFixture(.empty)).invoke(Self.action()))
        XCTAssertEqual((output["changes"] as? [Any])?.count,0)
        XCTAssertEqual((output["facts"] as? [Any])?.count,0)
        XCTAssertTrue(output["next"] is NSNull)
    }
    func testEntityFilterUsesExactEntityPolicyTarget() async throws {
        let fixture = ChangesQueryFixture(), gateway = try Self.gateway(fixture)
        let entity = ChangesQueryFixture.subject.uuidString.lowercased()
        let input = try Self.input(["subjectId":entity])
        do { _ = try await gateway.invoke(Self.action(input:input)); XCTFail("Global target accepted entity-scoped arguments") } catch { }
        let before = await fixture.calls; XCTAssertEqual(before,0)
        _ = try await gateway.invoke(Self.action(input:input,target:"entity:"+entity))
        let after = await fixture.calls; XCTAssertEqual(after,1)
    }
    func testPolicyActorAndScopeDenialPrecedesPortAccess() async throws {
        for variant in 0..<3 {
            let fixture = ChangesQueryFixture(), gateway = try Self.gateway(fixture,deny:variant == 0)
            do { _ = try await gateway.invoke(Self.action(actor:variant == 1 ? UUID() : Self.actor,
                scope:variant == 2 ? ["world:write"] : ["world:read"])); XCTFail("Denied read succeeded") } catch { }
            let count = await fixture.calls; XCTAssertEqual(count,0)
        }
    }
    func testMalformedAndUnboundedInputsNeverQuery() async throws {
        for fields: [String:Any] in [["from":"yesterday"],["to":"1970-01-01T00:00:00Z"],["limit":0],["limit":9],
            ["actorId":UUID().uuidString],["schemaVersion":"2"],["cursor":"invalid"],["knownAt":"1970-01-01T00:00:00-00:00"]] {
            let fixture = ChangesQueryFixture(), gateway = try Self.gateway(fixture)
            do { _ = try await gateway.invoke(Self.action(input:Self.input(fields))); XCTFail("Invalid input accepted") } catch { }
            let count = await fixture.calls; XCTAssertEqual(count,0)
        }
    }
    func testContinuationCannotChangeWindowFiltersKnowledgeOrActor() async throws {
        let firstFixture = ChangesQueryFixture()
        let first = try Self.output(await Self.gateway(firstFixture).invoke(Self.action()))
        let cursor = try XCTUnwrap(first["next"] as? String)
        for fields: [String:Any] in [["to":"1970-01-01T00:02:00Z"],["knownAt":"1970-01-01T00:04:00Z"],
            ["locationId":UUID().uuidString],["subjectId":ChangesQueryFixture.subject.uuidString]] {
            let fixture = ChangesQueryFixture(), gateway = try Self.gateway(fixture)
            var values = fields; values["cursor"] = cursor
            let target = fields["subjectId"] == nil ? "world:changes" : "entity:"+ChangesQueryFixture.subject.uuidString.lowercased()
            do { _ = try await gateway.invoke(Self.action(input:Self.input(values),target:target)); XCTFail("Cursor binding ignored") } catch { }
            let count = await fixture.calls; XCTAssertEqual(count,0)
        }
        let foreign = UUID(), fixture = ChangesQueryFixture()
        do { _ = try await Self.gateway(fixture,actor:foreign).invoke(Self.action(input:Self.input(["cursor":cursor]),actor:foreign)); XCTFail("Foreign cursor accepted") } catch { }
        let count = await fixture.calls; XCTAssertEqual(count,0)
    }
    func testFutureWatermarkIsAuthoritativelyRejectedByReadPort() async throws {
        let first = try Self.output(await Self.gateway(ChangesQueryFixture()).invoke(Self.action()))
        let cursor = try XCTUnwrap(first["next"] as? String)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(Data(base64Encoded:cursor))) as? [String:Any])
        value["throughSequence"] = 1000; value["availableThroughSequence"] = 1000
        let altered = try JSONSerialization.data(withJSONObject:value).base64EncodedString()
        let fixture = ChangesQueryFixture()
        do { _ = try await Self.gateway(fixture).invoke(Self.action(input:Self.input(["cursor":altered]))); XCTFail("Future watermark accepted") }
        catch { XCTAssertEqual(error as? ToolError,.invalidInput) }
        let count = await fixture.calls; XCTAssertEqual(count,1)
    }
    func testCorruptUnorderedOrExcessiveEvidenceFailsWithoutTruncation() async throws {
        for mode in [ChangesQueryFixture.Mode.wrongActor,.wrongSubject,.reversedOrder,.tooMany,.badNext,.excessiveEvidence,.badPrior] {
            let fixture = ChangesQueryFixture(mode), gateway = try Self.gateway(fixture)
            var fields: [String:Any] = [:]
            if mode == .reversedOrder { fields["limit"] = 2 }
            if mode == .wrongSubject { fields["subjectId"] = ChangesQueryFixture.subject.uuidString }
            let target = mode == .wrongSubject ? "entity:"+ChangesQueryFixture.subject.uuidString.lowercased() : "world:changes"
            do { _ = try await gateway.invoke(Self.action(input:Self.input(fields),target:target)); XCTFail("Corrupt output accepted: \(mode)") } catch { }
            let count = await fixture.calls; XCTAssertEqual(count,1)
        }
    }
    func testTouchedLocationFilterIncludesPriorEvidenceAndRejectsUnrelatedResults() async throws {
        let priorLocation = ChangesQueryFixture.uuid(103).uuidString
        let first = try Self.output(await Self.gateway(ChangesQueryFixture()).invoke(Self.action(input:Self.input(["locationId":priorLocation]))))
        XCTAssertEqual((first["facts"] as? [Any])?.count,2)
        let fixture = ChangesQueryFixture()
        do { _ = try await Self.gateway(fixture).invoke(Self.action(input:Self.input(["locationId":UUID().uuidString]))); XCTFail("Unrelated location accepted") } catch { }
        let count = await fixture.calls; XCTAssertEqual(count,1)
    }
    func testMalformedContinuationEnvelopeNeverReachesPort() async throws {
        let first = try Self.output(await Self.gateway(ChangesQueryFixture()).invoke(Self.action()))
        let cursor = try XCTUnwrap(first["next"] as? String)
        let bytes = try XCTUnwrap(Data(base64Encoded:cursor))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        for variant in 0..<3 {
            var value = original
            if variant == 0 { value["schemaVersion"] = "2" }
            if variant == 1 { value["extra"] = "private" }
            let altered: Data
            if variant == 2 {
                let text = try XCTUnwrap(String(data:bytes,encoding:.utf8))
                altered = Data(("{\"schemaVersion\":\"1\"," + text.dropFirst()).utf8)
            } else { altered = try JSONSerialization.data(withJSONObject:value) }
            let fixture = ChangesQueryFixture()
            do { _ = try await Self.gateway(fixture).invoke(Self.action(input:Self.input(["cursor":altered.base64EncodedString()]))); XCTFail("Invalid envelope accepted") } catch { }
            let count = await fixture.calls; XCTAssertEqual(count,0)
        }
    }
}
