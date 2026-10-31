import Foundation
import SquidraDomain
import SquidraPostgres
import SquidraWorld
import XCTest

private actor RecoveryJournalFixture: WorldRepository {
    enum Mode: Sendable { case normal, reversed, badCursor, incomplete, changedSnapshot, oversized, slow }
    private var events: [JournalEvent]
    let mode: Mode
    private var late: JournalEvent?
    private(set) var calls = 0
    init(_ events: [JournalEvent], mode: Mode = .normal, late: JournalEvent? = nil) { self.events = events; self.mode = mode; self.late = late }
    func append(_ event: WorldEventDraft, expectedVersion: Int64, idempotencyKey: String, deadline: ContinuousClock.Instant) throws -> JournalAppend { throw WorldJournalError.invalidEvent }
    func page(actorID: UUID, afterSequence: Int64, cursor: JournalCursor?, limit: Int, deadline: ContinuousClock.Instant) async throws -> JournalPage {
        calls += 1
        guard cursor == nil || afterSequence == 0 else { throw WorldJournalError.invalidCursor }
        if mode == .slow { try await Task.sleep(for:.seconds(30)) }
        let through = (cursor?.throughSequence ?? events.last?.sequence ?? 0) + (mode == .changedSnapshot && calls > 1 ? 1 : 0)
        if let late { events.append(late); self.late = nil }
        let after = cursor?.afterSequence ?? afterSequence
        let available = events.filter { $0.sequence > after && $0.sequence <= through }
        var page = Array(available.prefix(mode == .oversized ? limit+1 : limit))
        if mode == .reversed { page.reverse() }
        let last = page.last?.sequence ?? after
        let next = try last < through && mode != .incomplete
            ? JournalCursor(actorID:actorID,afterSequence:mode == .badCursor ? after : last,throughSequence:through) : nil
        return JournalPage(events:page,next:next,throughSequence:through)
    }
}
private actor RecoveryProjectorFixture: WorldProjector {
    let version: Int, slow: Bool, noProgress: Bool
    private var last: Int64?
    private(set) var applied: [UUID] = []
    init(last: Int64? = nil, version: Int = 1, slow: Bool = false, noProgress: Bool = false) {
        self.last = last; self.version = version; self.slow = slow; self.noProgress = noProgress
    }
    func apply(_ event: JournalEvent) async throws {
        if slow { try await Task.sleep(for:.seconds(30)) }
        applied.append(event.draft.id)
        if !noProgress { last = event.sequence }
    }
    func checkpoint() throws -> ProjectionCheckpoint {
        try ProjectionCheckpoint(projectionVersion:version,lastSequence:last,state:JSONDocument(Data("{}".utf8)))
    }
}

// SAFETY: stateless XCTest suite; all mutable fixtures are actors.
final class WorldRecoveryTests: XCTestCase, @unchecked Sendable {
    private static func events(actor: UUID, duplicateID: Bool = false) throws -> [JournalEvent] {
        let entity = UUID(), stream = UUID(), sharedID = UUID()
        return try [10,20,30].enumerated().map { index, sequence in
            let draft = try WorldEventDraft(id:duplicateID ? sharedID : UUID(),actorID:actor,streamID:stream,entityIDs:[entity],type:"fixture.observed",
                times:JournalTimes(occurredAt:nil,observedAt:UTCInstant(secondsSince1970:0),timeZone:IANATimeZone(identifier:"Etc/UTC")),
                sourceID:"fixture:recovery",confidence:Confidence(0.8),payloadVersion:1,payload:Data("{}".utf8),causationID:nil,correlationID:UUID())
            return try JournalEvent(sequence:Int64(sequence),streamVersion:Int64(index+1),draft:draft,recordedMicroseconds:Int64(sequence)*1_000_000)
        }
    }
    func testEmptyCacheAndExistingCheckpointReplayOnlyCapturedTail() async throws {
        let actor = UUID(), events = try Self.events(actor:actor), journal = RecoveryJournalFixture(events), projection = RecoveryProjectorFixture()
        let recovery = WorldProjectionRecovery(actorID:actor,repository:journal,projector:projection,limits:try WorldRecoveryLimits(pageSize:1))
        let first = try await recovery.recover()
        XCTAssertEqual(first.startSequence,0); XCTAssertEqual(first.capturedThroughSequence,30); XCTAssertEqual(first.projectedThroughSequence,30); XCTAssertEqual(first.replayedEvents,3)
        let repeated = try await recovery.recover()
        XCTAssertEqual(repeated.startSequence,30); XCTAssertEqual(repeated.replayedEvents,0)
        let applied = await projection.applied; XCTAssertEqual(applied,events.map(\.draft.id))
        let tailProjection = RecoveryProjectorFixture(last:10)
        let tail = try await WorldProjectionRecovery(actorID:actor,repository:journal,projector:tailProjection,limits:WorldRecoveryLimits(pageSize:1)).recover()
        XCTAssertEqual(tail.replayedEvents,2)
    }
    func testLateAppendStaysOutsideSnapshotAndNextRecoveryFindsIt() async throws {
        let actor = UUID(), events = try Self.events(actor:actor)
        let original = events[0].draft
        let draft = try WorldEventDraft(actorID:actor,streamID:original.streamID,entityIDs:original.entityIDs,type:original.type,
            times:original.times,sourceID:original.sourceID,confidence:original.confidence,payloadVersion:1,payload:original.payload.bytes,correlationID:UUID())
        let late = try JournalEvent(sequence:40,streamVersion:4,draft:draft,recordedMicroseconds:40_000_000)
        let journal = RecoveryJournalFixture(events,late:late), projection = RecoveryProjectorFixture()
        let recovery = WorldProjectionRecovery(actorID:actor,repository:journal,projector:projection,limits:try WorldRecoveryLimits(pageSize:1))
        let first = try await recovery.recover()
        XCTAssertEqual(first.capturedThroughSequence,30)
        let next = try await recovery.recover()
        XCTAssertEqual(next.startSequence,30); XCTAssertEqual(next.capturedThroughSequence,40); XCTAssertEqual(next.replayedEvents,1)
    }
    func testEventLimitLeavesAResumablePrefixAndDoesNotClaimCompletion() async throws {
        let actor = UUID(), journal = try RecoveryJournalFixture(Self.events(actor:actor)), projection = RecoveryProjectorFixture()
        do { _ = try await WorldProjectionRecovery(actorID:actor,repository:journal,projector:projection,limits:WorldRecoveryLimits(pageSize:1,maximumEvents:1)).recover(); XCTFail("Event limit ignored") }
        catch { XCTAssertEqual(error as? WorldRecoveryError,.eventLimit) }
        let checkpoint = try await projection.checkpoint(); XCTAssertEqual(checkpoint.lastSequence,10)
        let resumed = try await WorldProjectionRecovery(actorID:actor,repository:journal,projector:projection).recover()
        XCTAssertEqual(resumed.startSequence,10); XCTAssertEqual(resumed.replayedEvents,2)
    }
    func testMalformedWholePagesRejectBeforeAnyApply() async throws {
        let actor = UUID(), events = try Self.events(actor:actor)
        for mode in [RecoveryJournalFixture.Mode.reversed,.badCursor,.incomplete,.oversized] {
            let projection = RecoveryProjectorFixture(), journal = RecoveryJournalFixture(events,mode:mode)
            do { _ = try await WorldProjectionRecovery(actorID:actor,repository:journal,projector:projection,limits:WorldRecoveryLimits(pageSize:2)).recover(); XCTFail("Bad page accepted: \(mode)") }
            catch { XCTAssertEqual(error as? WorldRecoveryError,.invalidSnapshot) }
            let applied = await projection.applied; XCTAssertTrue(applied.isEmpty)
        }
    }
    func testForeignAndDuplicateEventIdentitiesRejectBeforeApply() async throws {
        let actor = UUID()
        for events in try [Self.events(actor:UUID()),Self.events(actor:actor,duplicateID:true)] {
            let projection = RecoveryProjectorFixture()
            do { _ = try await WorldProjectionRecovery(actorID:actor,repository:RecoveryJournalFixture(events),projector:projection).recover(); XCTFail("Foreign/duplicate event accepted") }
            catch { XCTAssertEqual(error as? WorldRecoveryError,.invalidSnapshot) }
            let applied = await projection.applied; XCTAssertTrue(applied.isEmpty)
        }
    }
    func testChangingWatermarkAndNoProgressCannotProduceSuccess() async throws {
        let actor = UUID(), events = try Self.events(actor:actor)
        let projection = RecoveryProjectorFixture()
        do { _ = try await WorldProjectionRecovery(actorID:actor,repository:RecoveryJournalFixture(events,mode:.changedSnapshot),projector:projection,limits:WorldRecoveryLimits(pageSize:1)).recover(); XCTFail("Changed watermark accepted") }
        catch { XCTAssertEqual(error as? WorldRecoveryError,.invalidSnapshot) }
        let applied = await projection.applied; XCTAssertEqual(applied.count,1)
        do { _ = try await WorldProjectionRecovery(actorID:actor,repository:RecoveryJournalFixture(events),projector:RecoveryProjectorFixture(noProgress:true)).recover(); XCTFail("Missing checkpoint progress accepted") }
        catch { XCTAssertEqual(error as? WorldRecoveryError,.invalidSnapshot) }
    }
    func testEmptyActorAndUnsupportedProjectionAreExplicit() async throws {
        let actor = UUID(), journal = RecoveryJournalFixture([])
        let empty = try await WorldProjectionRecovery(actorID:actor,repository:journal,projector:RecoveryProjectorFixture()).recover()
        XCTAssertEqual(empty.capturedThroughSequence,0); XCTAssertEqual(empty.replayedEvents,0)
        do { _ = try await WorldProjectionRecovery(actorID:actor,repository:journal,projector:RecoveryProjectorFixture(version:2)).recover(); XCTFail("Unsupported version accepted") }
        catch { XCTAssertEqual(error as? WorldRecoveryError,.unsupportedProjection) }
        XCTAssertThrowsError(try WorldRecoveryLimits(pageSize:0))
        XCTAssertThrowsError(try WorldRecoveryLimits(maximumEvents:0))
        XCTAssertThrowsError(try WorldRecoveryLimits(timeout:.zero))
    }
    func testMonotonicDeadlineCancelsCooperativeRepositoryAndProjector() async throws {
        let actor = UUID(), events = try Self.events(actor:actor)
        for slowProjection in [false,true] {
            let journal = RecoveryJournalFixture(events,mode:slowProjection ? .normal : .slow), projection = RecoveryProjectorFixture(slow:slowProjection)
            let start = ContinuousClock.now
            do { _ = try await WorldProjectionRecovery(actorID:actor,repository:journal,projector:projection,limits:WorldRecoveryLimits(timeout:.seconds(1))).recover(); XCTFail("Deadline ignored") }
            catch { XCTAssertEqual(error as? WorldRecoveryError,.deadlineExceeded) }
            XCTAssertLessThan(start.duration(to:.now),.seconds(5))
        }
    }
    func testExternalCancellationStopsRecoveryWithoutApplyingData() async throws {
        let actor = UUID(), journal = try RecoveryJournalFixture(Self.events(actor:actor),mode:.slow), projection = RecoveryProjectorFixture()
        let recovery = WorldProjectionRecovery(actorID:actor,repository:journal,projector:projection)
        let task = Task { try await recovery.recover() }
        for _ in 0..<200 {
            if await journal.calls > 0 { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        let calls = await journal.calls; XCTAssertEqual(calls,1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled recovery completed") }
        catch is CancellationError { }
        let applied = await projection.applied; XCTAssertTrue(applied.isEmpty)
    }
}
