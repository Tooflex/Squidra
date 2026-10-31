import Crypto
import Foundation
import SquidraDomain
import SquidraWorld
import XCTest

struct JournalFixture {
    struct Payload: Codable { let schemaVersion: String;let label: String }
    private struct Input: Decodable {
        let sequence: Int64,streamVersion: Int64,id: UUID,streamId: UUID,entityIds: [UUID],type: String
        let occurredMicroseconds: Int64?,observedMicroseconds: Int64,timeZone: String,sourceId: String,confidence: Double
        let payloadVersion: Int,payload: Payload,causationId: UUID?,correlationId: UUID
    }
    private struct File: Decodable { let schemaVersion: Int,actorId: UUID,events: [Input],expectedSHA256: String }
    let actorID: UUID,events: [JournalEvent],expectedSHA256: String
    static func load() throws -> Self {
        let path = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/journal.v1.json")
        let file = try JSONDecoder().decode(File.self,from:Data(contentsOf:path))
        guard file.schemaVersion == 1 else { throw WorldJournalError.unsupportedEvent }
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let events = try file.events.map { input in
            let times = try JournalTimes(occurredMicroseconds:input.occurredMicroseconds,observedMicroseconds:input.observedMicroseconds,timeZone:IANATimeZone(identifier:input.timeZone))
            let draft = try WorldEventDraft(id:input.id,actorID:file.actorId,streamID:input.streamId,entityIDs:input.entityIds,type:input.type,times:times,
                sourceID:input.sourceId,confidence:Confidence(input.confidence),payloadVersion:input.payloadVersion,payload:encoder.encode(input.payload),
                causationID:input.causationId,correlationID:input.correlationId)
            return try JournalEvent(sequence:input.sequence,streamVersion:input.streamVersion,draft:draft,recordedMicroseconds:input.observedMicroseconds+10)
        }
        return Self(actorID:file.actorId,events:events,expectedSHA256:file.expectedSHA256)
    }
    static func hash(_ checkpoint: ProjectionCheckpoint) -> String { SHA256.hash(data:checkpoint.state.bytes).map { String(format:"%02x",$0) }.joined() }
    static func changed(_ event: JournalEvent, payload: Data? = nil, version: Int? = nil, streamVersion: Int64? = nil) throws -> JournalEvent {
        let d = event.draft
        let draft = try WorldEventDraft(id:d.id,actorID:d.actorID,streamID:d.streamID,entityIDs:d.entityIDs,type:d.type,times:d.times,
            sourceID:d.sourceID,confidence:d.confidence,payloadVersion:version ?? d.payloadVersion,payload:payload ?? d.payload.bytes,
            causationID:d.causationID,correlationID:d.correlationID)
        return try JournalEvent(sequence:event.sequence,streamVersion:streamVersion ?? event.streamVersion,draft:draft,recordedMicroseconds:event.recordedMicroseconds)
    }
}
/// A versioned fixture projector; it does not claim spatial business projection.
actor LabelFixtureProjector: WorldProjector {
    let actorID: UUID
    private var seen: [UUID:JournalEvent] = [:],versions: [UUID:Int64] = [:],labels: [UUID:String] = [:]
    private var last: Int64?
    init(actorID: UUID) { self.actorID = actorID }
    func apply(_ event: JournalEvent) throws {
        let draft = event.draft
        guard draft.actorID == actorID else { throw WorldJournalError.invalidEvent }
        if let old = seen[draft.id] {
            guard old == event else { throw WorldJournalError.idempotencyConflict };return
        }
        guard draft.payloadVersion == 1,["fixture.label_set","fixture.label_corrected"].contains(draft.type) else { throw WorldJournalError.unsupportedEvent }
        let version = versions[draft.streamID] ?? 0
        guard version < Int64.max,event.streamVersion == version+1,event.sequence > (last ?? 0) else { throw WorldJournalError.versionConflict }
        guard draft.entityIDs.count == 1,let entity = draft.entityIDs.first else { throw WorldJournalError.invalidEvent }
        let payload = try JSONDecoder().decode(JournalFixture.Payload.self,from:draft.payload.bytes)
        guard payload.schemaVersion == "1",!payload.label.isEmpty,payload.label.utf8.count <= 128 else { throw WorldJournalError.unsupportedEvent }
        if draft.type == "fixture.label_corrected" {
            guard let cause = draft.causationID,seen[cause]?.draft.entityIDs == draft.entityIDs,labels[entity] != nil else { throw WorldJournalError.invalidEvent }
        } else { guard draft.causationID == nil,labels[entity] == nil else { throw WorldJournalError.invalidEvent } }
        labels[entity] = payload.label;versions[draft.streamID] = event.streamVersion;seen[draft.id] = event;last = event.sequence
    }
    func checkpoint() throws -> ProjectionCheckpoint {
        struct Label: Encodable { let entityId: String,label: String }
        struct State: Encodable {
            let schemaVersion = "1",projectionVersion = 1
            let actorId: String,lastSequence: Int64?,labels: [Label]
        }
        let values = labels.map { Label(entityId:$0.key.uuidString.lowercased(),label:$0.value) }.sorted { $0.entityId < $1.entityId }
        let state = State(actorId:actorID.uuidString.lowercased(),lastSequence:last,labels:values)
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        return try ProjectionCheckpoint(projectionVersion:1,lastSequence:last,state:JSONDocument(encoder.encode(state)))
    }
}

// SAFETY: stateless suite; the projector keeps mutable state in an actor.
final class WorldJournalTests: XCTestCase, @unchecked Sendable {
    func testVersionedFixtureHasIdenticalGoldenRebuildAndDuplicateReplay() async throws {
        let fixture = try JournalFixture.load(),single = LabelFixtureProjector(actorID:fixture.actorID),replay = LabelFixtureProjector(actorID:fixture.actorID)
        for event in fixture.events { try await single.apply(event) }
        for chunk in [Array(fixture.events.prefix(2)),Array(fixture.events.suffix(2))] {
            for event in chunk { try await replay.apply(event);try await replay.apply(event) }
        }
        // Duplicate delivery after advancing the checkpoint is also a no-op.
        try await replay.apply(fixture.events[0])
        let first = try await single.checkpoint(),second = try await replay.checkpoint()
        XCTAssertEqual(first.state.bytes,second.state.bytes);XCTAssertEqual(JournalFixture.hash(first),fixture.expectedSHA256)
        XCTAssertEqual(first.lastSequence,4);XCTAssertEqual(first.projectionVersion,1)
    }
    func testUnsupportedVersionsGapsAndConflictingDuplicatesFail() async throws {
        let fixture = try JournalFixture.load(),event = fixture.events[0]
        do { try await LabelFixtureProjector(actorID:fixture.actorID).apply(JournalFixture.changed(event,version:2));XCTFail("Unknown version replayed") }
        catch { XCTAssertEqual(error as? WorldJournalError,.unsupportedEvent) }
        do { try await LabelFixtureProjector(actorID:fixture.actorID).apply(JournalFixture.changed(event,streamVersion:2));XCTFail("Version gap replayed") }
        catch { XCTAssertEqual(error as? WorldJournalError,.versionConflict) }
        let projector = LabelFixtureProjector(actorID:fixture.actorID);try await projector.apply(event)
        do { try await projector.apply(JournalFixture.changed(event,payload:Data(#"{"schemaVersion":"1","label":"forged"}"#.utf8)));XCTFail("Conflicting duplicate replayed") }
        catch { XCTAssertEqual(error as? WorldJournalError,.idempotencyConflict) }
    }
    func testCorrectionKeepsOriginalEventAndRebuildsNewLabel() async throws {
        let fixture = try JournalFixture.load(),projector = LabelFixtureProjector(actorID:fixture.actorID),original = fixture.events[0].draft.payload.bytes
        for event in fixture.events { try await projector.apply(event) }
        XCTAssertEqual(fixture.events[0].draft.payload.bytes,original)
        let checkpoint = try await projector.checkpoint()
        XCTAssertTrue(String(decoding:checkpoint.state.bytes,as:UTF8.self).contains("Room B"))
        XCTAssertEqual(fixture.events[2].draft.causationID,fixture.events[0].draft.id)
    }
    func testDraftRejectsInvalidPayloadAndMetadataBeforePersistence() throws {
        let original = try JournalFixture.load().events[0].draft
        for payload in ["[]",#"{"x":1,"x":2}"#,#"{"x":"\u0000"}"#,"{} trailing"] {
            XCTAssertThrowsError(try WorldEventDraft(actorID:original.actorID,streamID:original.streamID,entityIDs:original.entityIDs,type:original.type,
                times:original.times,sourceID:original.sourceID,confidence:original.confidence,payloadVersion:1,payload:Data(payload.utf8),correlationID:UUID()))
        }
        for ids: [UUID] in [[],Array(repeating:UUID(),count:257)] {
            XCTAssertThrowsError(try WorldEventDraft(actorID:original.actorID,streamID:original.streamID,entityIDs:ids,type:original.type,
                times:original.times,sourceID:original.sourceID,confidence:original.confidence,payloadVersion:1,payload:original.payload.bytes,correlationID:UUID()))
        }
    }
    func testMicrosecondPrecisionUnknownOccurrenceAndCursorBounds() throws {
        let times = try JournalTimes(occurredAt:nil,observedAt:UTCInstant(secondsSince1970:1.1234567),timeZone:IANATimeZone(identifier:"Europe/Paris"))
        XCTAssertNil(times.occurredAt);XCTAssertEqual(times.observedMicroseconds,1_123_457);XCTAssertEqual(times.timeZone.identifier,"Europe/Paris")
        XCTAssertThrowsError(try JournalTimes(occurredMicroseconds:nil,observedMicroseconds:Int64.max,timeZone:times.timeZone))
        XCTAssertThrowsError(try JournalTimes(occurredMicroseconds:nil,observedMicroseconds:253_402_300_799_999_999,timeZone:times.timeZone))
        XCTAssertThrowsError(try JournalCursor(actorID:UUID(),afterSequence:-1,throughSequence:0))
        XCTAssertThrowsError(try JournalCursor(actorID:UUID(),afterSequence:2,throughSequence:1))
    }
}
