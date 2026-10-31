import Foundation
import SquidraDomain
import SquidraWorld
import XCTest

final class WorldChangesTests: XCTestCase {
    private static func instant(_ seconds: Double) throws -> UTCInstant { try UTCInstant(secondsSince1970:seconds) }
    func testFinitePositiveWindowAndIndependentKnowledgeTime() throws {
        let actor = UUID()
        XCTAssertThrowsError(try WorldChangesQuery(actorID:actor,from:Self.instant(1),to:nil,knownAt:Self.instant(2)))
        XCTAssertThrowsError(try WorldChangesQuery(actorID:actor,from:Self.instant(1),to:Self.instant(1),knownAt:Self.instant(2)))
        XCTAssertThrowsError(try WorldChangesQuery(actorID:actor,from:Self.instant(2),to:Self.instant(1),knownAt:Self.instant(2)))
        let query = try WorldChangesQuery(actorID:actor,from:Self.instant(1),to:Self.instant(2),knownAt:Self.instant(0.5))
        XCTAssertEqual(query.window.fromMicroseconds,1_000_000);XCTAssertEqual(query.window.toMicroseconds,2_000_000)
        XCTAssertEqual(query.knownMicroseconds,500_000)
    }
    func testCursorBindsActorFiltersWindowKnowledgeAndWatermark() throws {
        let actor = UUID(),subject = UUID(),location = UUID()
        let query = try WorldChangesQuery(actorID:actor,from:Self.instant(1),to:Self.instant(3),knownAt:Self.instant(4),subjectID:subject,locationID:location)
        let cursor = try WorldChangesCursor(query:query,throughSequence:2,availableThroughSequence:3,afterValidMicroseconds:1_000_000,afterFactID:UUID())
        XCTAssertEqual(cursor.query,query)
        XCTAssertNotEqual(query,try WorldChangesQuery(actorID:UUID(),from:Self.instant(1),to:Self.instant(3),knownAt:Self.instant(4),subjectID:subject,locationID:location))
        XCTAssertNotEqual(query,try WorldChangesQuery(actorID:actor,from:Self.instant(1),to:Self.instant(3),knownAt:Self.instant(5),subjectID:subject,locationID:location))
        XCTAssertThrowsError(try WorldChangesCursor(query:query,throughSequence:4,availableThroughSequence:3,afterValidMicroseconds:1_000_000,afterFactID:UUID()))
        XCTAssertThrowsError(try WorldChangesCursor(query:query,throughSequence:2,availableThroughSequence:3,afterValidMicroseconds:3_000_000,afterFactID:UUID()))
    }
    func testUnknownPriorIsObservationAndAdjacentEvidenceSupportsStateChange() throws {
        let actor = UUID(),subject = UUID(),frame = UUID(),placeA = UUID(),placeB = UUID()
        let previous = try fact(actor:actor,subject:subject,frame:frame,place:placeA,from:0,to:1_000_000)
        let current = try fact(actor:actor,subject:subject,frame:frame,place:placeB,from:1_000_000,to:2_000_000)
        let initial = try WorldChange(current:current,previous:[],isCorrection:false,conflictingCurrent:false,projectionBehind:false)
        XCTAssertEqual(initial.kind,.observation);XCTAssertEqual(initial.uncertainty,[.priorStateUnknown])
        let change = try WorldChange(current:current,previous:[previous],isCorrection:false,conflictingCurrent:false,projectionBehind:false)
        XCTAssertEqual(change.kind,.locationChanged)
        XCTAssertEqual(Set(change.supportingEventIDs),[previous.sourceEventID,current.sourceEventID])
    }
    func testCorrectionsAndConflictingInferencesNeverBecomeCertainMovement() throws {
        let actor = UUID(),subject = UUID(),frame = UUID()
        let prior = try fact(actor:actor,subject:subject,frame:frame,place:UUID(),from:0,to:1_000_000)
        let current = try fact(actor:actor,subject:subject,frame:frame,place:UUID(),from:1_000_000,to:2_000_000,basis:.inferred)
        let correction = try WorldChange(current:current,previous:[prior],isCorrection:true,conflictingCurrent:false,projectionBehind:false)
        XCTAssertEqual(correction.kind,.correction);XCTAssertTrue(correction.uncertainty.contains(.inferredEvidence))
        let conflicting = try WorldChange(current:current,previous:[prior],isCorrection:false,conflictingCurrent:true,projectionBehind:true)
        XCTAssertEqual(conflicting.kind,.observation);XCTAssertEqual(conflicting.uncertainty,[.inferredEvidence,.conflictingLocations,.projectionBehind])
        XCTAssertThrowsError(try WorldChange(current:current,previous:[],isCorrection:true,conflictingCurrent:false,projectionBehind:false))
        let foreign = try fact(actor:UUID(),subject:subject,frame:frame,place:UUID(),from:0,to:1_000_000)
        XCTAssertThrowsError(try WorldChange(current:current,previous:[foreign],isCorrection:false,conflictingCurrent:false,projectionBehind:false))
    }
    private func fact(actor: UUID, subject: UUID, frame: UUID, place: UUID, from: Int64, to: Int64?, basis: LocationBasis = .observed) throws -> WorldLocationFact {
        let event = UUID(),instant = try Self.instant(1)
        return try WorldLocationFact(id:event,actorID:actor,subjectID:subject,locationID:place,frameID:frame,
            valid:FactInterval(fromMicroseconds:from,toMicroseconds:to),transaction:FactInterval(fromMicroseconds:0,toMicroseconds:nil),
            confidence:Confidence(0.8),basis:basis,sourceID:"fixture:changes",sourceEventID:event,
            timestamps:ObservationTimestamps(occurredAt:nil,observedAt:instant,recordedAt:instant,timeZone:IANATimeZone(identifier:"Etc/UTC")))
    }
}
