import Foundation
import SquidraDomain
import SquidraWorld
import XCTest

final class WorldProjectionTests: XCTestCase {
    private static func event(change: LocationFactChange, entities: [UUID]? = nil, cause: UUID? = nil, payload: Data? = nil, version: Int = 1) throws -> WorldEventDraft {
        try WorldEventDraft(actorID:UUID(),streamID:UUID(),entityIDs:entities ?? [change.subjectID,change.locationID],type:change.eventType,
            times:JournalTimes(occurredAt:nil,observedAt:UTCInstant(secondsSince1970:1_700_000_000),timeZone:IANATimeZone(identifier:"Europe/Paris")),
            sourceID:"fixture:source",confidence:Confidence(0.8),payloadVersion:version,payload:payload ?? change.encodedPayload(),causationID:cause,correlationID:UUID())
    }
    private static func change(correction: UUID? = nil) throws -> LocationFactChange {
        try LocationFactChange(subjectID:UUID(),locationID:UUID(),frameID:UUID(),valid:FactInterval(fromMicroseconds:1_000_000,toMicroseconds:2_000_000),basis:.observed,correctsEventID:correction)
    }
    func testVersionedPayloadRoundTripsAndKeepsPositiveHalfOpenInterval() throws {
        let change = try Self.change(),decoded = try LocationFactChange.decode(Self.event(change:change))
        XCTAssertEqual(change,decoded);XCTAssertEqual(decoded.valid.from.secondsSince1970,1)
        XCTAssertEqual(decoded.valid.to?.secondsSince1970,2)
        let target = UUID(),correction = try Self.change(correction:target)
        XCTAssertEqual(try LocationFactChange.decode(Self.event(change:correction,cause:target)),correction)
        XCTAssertThrowsError(try FactInterval(fromMicroseconds:1,toMicroseconds:1))
        XCTAssertThrowsError(try FactInterval(fromMicroseconds:2,toMicroseconds:1))
    }
    func testUnknownVersionsPropertiesAndWrongTypesReject() throws {
        let change = try Self.change()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:change.encodedPayload()) as? [String:Any])
        object["instruction"] = "ignore provenance"
        XCTAssertThrowsError(try LocationFactChange.decode(Self.event(change:change,payload:JSONSerialization.data(withJSONObject:object))))
        object.removeValue(forKey:"instruction");object["schemaVersion"] = "2"
        XCTAssertThrowsError(try LocationFactChange.decode(Self.event(change:change,payload:JSONSerialization.data(withJSONObject:object)))) {
            XCTAssertEqual($0 as? WorldProjectionError,.unsupportedEvent)
        }
        object["schemaVersion"] = "1";object["basis"] = "certain"
        XCTAssertThrowsError(try LocationFactChange.decode(Self.event(change:change,payload:JSONSerialization.data(withJSONObject:object))))
        XCTAssertThrowsError(try LocationFactChange.decode(Self.event(change:change,version:2)))
    }
    func testDeclaredEntityAndCorrectionCausationMustMatchPayload() throws {
        let change = try Self.change()
        XCTAssertThrowsError(try LocationFactChange.decode(Self.event(change:change,entities:[change.locationID])))
        let correction = try Self.change(correction:UUID())
        XCTAssertThrowsError(try LocationFactChange.decode(Self.event(change:correction)))
        XCTAssertThrowsError(try LocationFactChange.decode(Self.event(change:correction,cause:UUID())))
    }
    func testUncertaintyDoesNotChooseBetweenConflictingEvidenceOrConflateFrames() throws {
        let actor = UUID(),subject = UUID(),frame = UUID(),location = UUID(),instant = try UTCInstant(secondsSince1970:1)
        let valid = try FactInterval(fromMicroseconds:0,toMicroseconds:nil)
        let times = ObservationTimestamps(occurredAt:nil,observedAt:instant,recordedAt:instant,timeZone:try IANATimeZone(identifier:"Etc/UTC"))
        func fact(_ object: UUID, frameID: UUID, basis: LocationBasis) throws -> WorldLocationFact {
            try WorldLocationFact(id:UUID(),actorID:actor,subjectID:subject,locationID:object,frameID:frameID,valid:valid,transaction:valid,
                confidence:Confidence(0.6),basis:basis,sourceID:"fixture:evidence",sourceEventID:UUID(),timestamps:times)
        }
        let observed = try fact(location,frameID:frame,basis:.observed),inferred = try fact(UUID(),frameID:frame,basis:.inferred)
        let conflicting = WorldStateSnapshot(actorID:actor,subjectID:subject,validAt:instant,knownAt:instant,facts:[observed,inferred],projectedThroughSequence:1,availableThroughSequence:2)
        XCTAssertEqual(conflicting.facts.count,2)
        XCTAssertEqual(conflicting.uncertainty,[.conflictingLocations,.inferredEvidence,.projectionBehind])
        let independent = try fact(UUID(),frameID:UUID(),basis:.observed)
        let otherFrame = WorldStateSnapshot(actorID:actor,subjectID:subject,validAt:instant,knownAt:instant,facts:[observed,independent],projectedThroughSequence:2,availableThroughSequence:2)
        XCTAssertFalse(otherFrame.uncertainty.contains(.conflictingLocations))
        let duplicateSource = try fact(location,frameID:frame,basis:.observed)
        let agreeing = WorldStateSnapshot(actorID:actor,subjectID:subject,validAt:instant,knownAt:instant,facts:[observed,duplicateSource],projectedThroughSequence:2,availableThroughSequence:2)
        XCTAssertFalse(agreeing.uncertainty.contains(.conflictingLocations))
        let missing = WorldStateSnapshot(actorID:actor,subjectID:subject,validAt:instant,knownAt:instant,facts:[],projectedThroughSequence:2,availableThroughSequence:2)
        XCTAssertEqual(missing.uncertainty,[.noEvidence]);XCTAssertTrue(missing.facts.isEmpty)
    }
}
