import Crypto
import Foundation
import JSONSchema
import SquidraCognition
import SquidraDomain
@testable import SquidraProtocols
import SquidraWorld
import XCTest

// SAFETY: stateless suite; all producer/validator state is local to each test.
final class AGUIContractTests: XCTestCase, @unchecked Sendable {
    private static var root: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private static func data(_ path:String) throws -> Data { try Data(contentsOf:root.appendingPathComponent(path)) }
    private static func object(_ bytes:Data) throws -> [String:Any] { try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any]) }
    private static func digest(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private static func schema() throws -> Schema {
        // Trusted immutable schema artifact, not runtime untrusted event input.
        try Schema(rawSchema:JSONValue.parse(data("Schemas/protocols/ag-ui.1.0.schema.json")),context:.init(dialect:.draft2020_12,remoteSchema:[:]))
    }
    private static func binding() -> AGUIRunBinding { AGUIRunBinding(actorID:UUID(),runID:UUID(),threadID:UUID(),requestID:UUID()) }
    private static func answer(_ binding:AGUIRunBinding) throws -> GroundedAnswer {
        let subject = UUID(),time = try UTCInstant(secondsSince1970:1_700_000_000)
        let snapshot = WorldStateSnapshot(actorID:binding.actorID,subjectID:subject,validAt:time,knownAt:time,facts:[],projectedThroughSequence:0,availableThroughSequence:0)
        let context = try AnswerEvidenceContext(snapshot:snapshot,expectedActor:binding.actorID,intent:.current,
            clock:FixedClock(instant:time,timeZone:IANATimeZone(identifier:"UTC")),policy:AnswerFreshnessPolicy(maximumObservationAgeSeconds:60,minimumCurrentConfidence:Confidence(0.5)))
        let text = String(decoding:try JSONSerialization.data(withJSONObject:["schemaVersion":"1","claims":[["kind":"unknown","subjectId":subject.uuidString,"citations":[]]]]),as:UTF8.self)
        let response = ModelResponse(schemaVersion:"1",requestID:binding.requestID,modelID:"fixture",modelVersion:"1",text:text,outputTokens:1,costMicroUSD:0)
        return try GroundedAnswerValidator().validate(response,expectedRequestID:binding.requestID,context:context)
    }
    private static func events(_ binding:AGUIRunBinding) throws -> [AGUIEvent] {
        let at = try UTCInstant(secondsSince1970:-0.125)
        return try [AGUIEvent.started(binding:binding,at:at)]+AGUIEvent.answer(answer(binding),binding:binding,messageID:UUID(),at:at)+[AGUIEvent.finished(binding:binding,at:at)]
    }
    private static func token(_ object:[String:Any]) throws -> String {
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes]).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }
    func testImmutableOfficialSchemaLicenseAndSixteenEventFixtures() throws {
        let catalog = try Self.object(Self.data("fixtures/protocols/agui.1.0-selected.json")),schema = try Self.schema()
        XCTAssertEqual(catalog["revision"] as? String,"1a9b3db4ea5145f263c66049e836c8896df66269")
        XCTAssertEqual(catalog["schemaSHA256"] as? String,Self.digest(try Self.data("Schemas/protocols/ag-ui.1.0.schema.json")))
        XCTAssertEqual(catalog["licenseSHA256"] as? String,Self.digest(try Self.data("Schemas/protocols/ag-ui.LICENSE")))
        XCTAssertTrue(try schema.validateAgainstMetaSchema().isValid)
        let fixtures = try XCTUnwrap(catalog["events"] as? [[String:Any]])
        XCTAssertEqual(fixtures.count,16)
        for fixture in fixtures {
            let original = Data(try XCTUnwrap(fixture["originalUTF8"] as? String).utf8)
            XCTAssertEqual(Self.digest(original),fixture["sha256"] as? String)
            XCTAssertEqual(schema.validate(try JSONValue.parse(original)).isValid,fixture["valid"] as? Bool,fixture["path"] as? String ?? "fixture")
        }
    }
    func testTypedGroundedProducerEmitsOfficialEventsAndIntegerMilliseconds() throws {
        let binding = Self.binding(),events = try Self.events(binding),schema = try Self.schema()
        XCTAssertEqual(events.count,6)
        var validator = AGUIStreamValidator(binding:binding)
        for (index,event) in events.enumerated() {
            XCTAssertTrue(schema.validate(try JSONValue.parse(event.json)).isValid)
            XCTAssertEqual(try Self.object(event.json)["timestamp"] as? Int,-125)
            try validator.accept(event.json,sequence:Int64(index+1))
        }
        XCTAssertTrue(validator.isTerminal);XCTAssertEqual(validator.nextSequence,7)
        let custom = try Self.object(events[1].json)
        XCTAssertEqual(custom["name"] as? String,"squidra.grounded_answer.v1")
        let value = try XCTUnwrap(custom["value"] as? [String:Any]);XCTAssertEqual(value["status"] as? String,"unknown")
        let actor = try XCTUnwrap(value["actorId"] as? String);XCTAssertEqual(UUID(uuidString:actor),binding.actorID)
        XCTAssertNil(custom["rawEvent"]);XCTAssertNil(custom["input"])
    }
    func testActorAndRequestProofCannotBeReboundToAnotherRunContext() throws {
        let binding = Self.binding(),answer = try Self.answer(binding),at = try UTCInstant(secondsSince1970:0)
        for foreign in [AGUIRunBinding(actorID:UUID(),runID:binding.runID,threadID:binding.threadID,requestID:binding.requestID),AGUIRunBinding(actorID:binding.actorID,runID:binding.runID,threadID:binding.threadID,requestID:UUID())] {
            XCTAssertThrowsError(try AGUIEvent.answer(answer,binding:foreign,messageID:UUID(),at:at)) { XCTAssertEqual($0 as? AGUIError,.scopeMismatch) }
        }
        let event = try AGUIEvent.started(binding:binding,at:at)
        XCTAssertThrowsError(try AGUIStreamRecord(binding:Self.binding(),sequence:1,event:event))
    }
    func testSixOfficialStreamFixturesRetainTheirAcceptedRejectedOutcomes() throws {
        let catalog = try Self.object(Self.data("fixtures/protocols/agui.1.0-selected.json")),fixtures = try XCTUnwrap(catalog["streams"] as? [[String:Any]])
        XCTAssertEqual(fixtures.count,6)
        for fixture in fixtures {
            let bytes = Data(try XCTUnwrap(fixture["originalUTF8"] as? String).utf8)
            XCTAssertEqual(Self.digest(bytes),fixture["sha256"] as? String)
            let source = try Self.object(bytes),stream = try XCTUnwrap(source["stream"] as? [[String:Any]])
            let start = stream.first { $0["type"] as? String == "RUN_STARTED" }
            var validator = AGUIStreamValidator(threadID:start?["threadId"] as? String ?? "t",runID:start?["runId"] as? String ?? "r")
            var rejected = false
            do {
                for (index,event) in stream.enumerated() { try validator.accept(JSONSerialization.data(withJSONObject:event),sequence:Int64(index+1)) }
            } catch { rejected = true }
            let expectation = try XCTUnwrap(source["expect"] as? [String:Any])
            XCTAssertEqual(rejected,expectation["outcome"] as? String == "failed",source["name"] as? String ?? "stream")
            if !rejected { XCTAssertTrue(validator.isTerminal) }
        }
    }
    func testChronologyScopeNullsAndVersionFailuresLeaveStateUnchanged() throws {
        let binding = Self.binding(),events = try Self.events(binding)
        var validator = AGUIStreamValidator(binding:binding)
        try validator.accept(events[0].json,sequence:1)
        XCTAssertThrowsError(try validator.accept(events[1].json,sequence:3));XCTAssertEqual(validator.nextSequence,2)
        try validator.accept(events[1].json,sequence:2);try validator.accept(events[2].json,sequence:3)
        XCTAssertThrowsError(try validator.accept(events[5].json,sequence:4));XCTAssertEqual(validator.nextSequence,4)
        for field in ["messageId","timestamp","rawEvent"] {
            var object = try Self.object(events[3].json)
            object[field] = field == "messageId" ? UUID().uuidString : NSNull()
            XCTAssertThrowsError(try validator.accept(JSONSerialization.data(withJSONObject:object),sequence:4))
            XCTAssertEqual(validator.nextSequence,4)
        }
        try validator.accept(events[3].json,sequence:4);try validator.accept(events[4].json,sequence:5);try validator.accept(events[5].json,sequence:6)
        XCTAssertThrowsError(try validator.accept(events[0].json,sequence:7))
        var fresh = AGUIStreamValidator(binding:binding),wrongVersion = try Self.object(events[0].json)
        wrongVersion["protocolVersion"] = "2.0"
        XCTAssertThrowsError(try fresh.accept(JSONSerialization.data(withJSONObject:wrongVersion),sequence:1)) { XCTAssertEqual($0 as? AGUIError,.unsupportedVersion) }
        XCTAssertEqual(fresh.nextSequence,1)
    }
    func testStaticFailureAndCancelledCompletionMatchOfficialSchema() throws {
        let binding = Self.binding(),at = try UTCInstant(secondsSince1970:0),schema = try Self.schema()
        let failure = try AGUIEvent.failed(binding:binding,at:at,code:.recoveryRequired)
        XCTAssertTrue(schema.validate(try JSONValue.parse(failure.json)).isValid)
        let object = try Self.object(failure.json)
        XCTAssertNil(object["runId"]);XCTAssertNil(object["threadId"]);XCTAssertEqual(object["code"] as? String,"RUN_RECOVERY_REQUIRED")
        let cancelled = try AGUIEvent.finished(binding:binding,at:at,outcome:.cancelled)
        XCTAssertTrue(schema.validate(try JSONValue.parse(cancelled.json)).isValid)
    }
    func testOpaqueCursorIsCanonicalScopedExactAndHasExplicitRetentionErrors() throws {
        let binding = Self.binding(),cursor = try AGUIResumeCursor(actorID:binding.actorID,runID:binding.runID,afterSequence:Int64.max-1)
        XCTAssertEqual(try AGUIResumeCursor.decode(cursor.encoded()),cursor)
        let raw: [String:Any] = ["schemaVersion":"1","actorId":binding.actorID.uuidString.lowercased(),"runId":binding.runID.uuidString.lowercased(),"afterSequence":"2"]
        for (key,value) in [("schemaVersion","2" as Any),("afterSequence","02"),("afterSequence",2),("extra",true)] {
            var object = raw;object[key] = value
            XCTAssertThrowsError(try AGUIResumeCursor.decode(Self.token(object)))
        }
        XCTAssertThrowsError(try AGUIResumeCursor.decode(cursor.encoded()+"="))
        let bounds = try AGUIReplayBounds(actorID:binding.actorID,runID:binding.runID,minimumRetainedSequence:3,nextSequence:8)
        func token(_ sequence:Int64,actor:UUID? = nil) throws -> String { try AGUIResumeCursor(actorID:actor ?? binding.actorID,runID:binding.runID,afterSequence:sequence).encoded() }
        XCTAssertEqual(try bounds.afterSequence(for:token(2)),2);XCTAssertEqual(try bounds.afterSequence(for:token(7)),7)
        XCTAssertThrowsError(try bounds.afterSequence(for:token(1))) { XCTAssertEqual($0 as? AGUIError,.cursorOutsideRetention) }
        XCTAssertThrowsError(try bounds.afterSequence(for:nil)) { XCTAssertEqual($0 as? AGUIError,.cursorOutsideRetention) }
        XCTAssertThrowsError(try bounds.afterSequence(for:token(8))) { XCTAssertEqual($0 as? AGUIError,.invalidCursor) }
        XCTAssertThrowsError(try bounds.afterSequence(for:token(2,actor:UUID()))) { XCTAssertEqual($0 as? AGUIError,.invalidCursor) }
        let empty = try AGUIReplayBounds(actorID:binding.actorID,runID:binding.runID,minimumRetainedSequence:1,nextSequence:1)
        XCTAssertEqual(try empty.afterSequence(for:nil),0)
    }
    func testSSEEscapesContentAndCannotInjectIDsOrEvents() throws {
        let binding = Self.binding(),message = "line1\n\nid: attacker\ndata: injected\r\n雪\u{2028}end"
        let bytes = try JSONSerialization.data(withJSONObject:["type":"TEXT_MESSAGE_CONTENT","messageId":UUID().uuidString,"delta":message])
        let event = try AGUIEvent(binding:binding,kind:.textContent,json:bytes),record = try AGUIStreamRecord(binding:binding,sequence:9,event:event)
        let encoded = String(decoding:try record.encodedSSE(),as:UTF8.self),lines = encoded.components(separatedBy:"\n")
        XCTAssertEqual(lines.count,4);XCTAssertTrue(lines[0].hasPrefix("id: "));XCTAssertTrue(lines[1].hasPrefix("data: "));XCTAssertEqual(lines[2...3],["",""])
        let cursor = try AGUIResumeCursor.decode(String(lines[0].dropFirst(4)));XCTAssertEqual(cursor.afterSequence,9);XCTAssertEqual(cursor.actorID,binding.actorID)
        let decoded = try Self.object(Data(lines[1].dropFirst(6).utf8));XCTAssertEqual(decoded["delta"] as? String,message)
        XCTAssertEqual(AGUIStreamRecord.heartbeat,Data(": keepalive\n\n".utf8))
        let pretty = try JSONSerialization.data(withJSONObject:["type":"TEXT_MESSAGE_CONTENT","messageId":"m","delta":"x"],options:.prettyPrinted)
        let malformed = try AGUIEvent(binding:binding,kind:.textContent,json:pretty)
        XCTAssertThrowsError(try AGUIStreamRecord(binding:binding,sequence:1,event:malformed).encodedSSE())
    }
    func testBoundedStreamReservesLastEventForTerminalAndAcceptsOfficialEmptyDelta() throws {
        let binding = Self.binding(),at = try UTCInstant(secondsSince1970:0),id = UUID().uuidString
        var validator = AGUIStreamValidator(binding:binding)
        try validator.accept(AGUIEvent.started(binding:binding,at:at).json,sequence:1)
        let start = try JSONSerialization.data(withJSONObject:["type":"TEXT_MESSAGE_START","messageId":id])
        let delta = try JSONSerialization.data(withJSONObject:["type":"TEXT_MESSAGE_CONTENT","messageId":id,"delta":""])
        try validator.accept(start,sequence:2)
        for sequence in 3...126 { try validator.accept(delta,sequence:Int64(sequence)) }
        try validator.accept(JSONSerialization.data(withJSONObject:["type":"TEXT_MESSAGE_END","messageId":id]),sequence:127)
        XCTAssertThrowsError(try validator.accept(start,sequence:128));XCTAssertEqual(validator.nextSequence,128)
        try validator.accept(AGUIEvent.finished(binding:binding,at:at).json,sequence:128);XCTAssertTrue(validator.isTerminal)
        let huge = try JSONSerialization.data(withJSONObject:["type":"TEXT_MESSAGE_CONTENT","messageId":id,"delta":String(repeating:"x",count:70_000)])
        XCTAssertThrowsError(try AGUIEvent(binding:binding,kind:.textContent,json:huge)) { XCTAssertEqual($0 as? AGUIError,.eventTooLarge) }
    }
}
