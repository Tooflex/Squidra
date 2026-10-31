import Foundation
import SquidraDomain
import SquidraPerception
import XCTest

private actor AssociationStoreFixture: EntityAssociationStore {
    enum Mode: Sendable { case normal, conflict, ambiguousCommit, foreign, slow }
    var state: EntityAssociationState?
    let mode: Mode
    private(set) var writes = 0
    private(set) var cancelled = false
    init(_ mode: Mode = .normal, state: EntityAssociationState? = nil) { self.mode = mode; self.state = state }
    func load(actorID: UUID, cameraID: UUID, deadline: ContinuousClock.Instant) async throws -> EntityAssociationState? {
        if mode == .slow {
            do { try await ContinuousClock().sleep(for:.seconds(30)) }
            catch { cancelled = true; throw error }
        }
        return state
    }
    func compareAndSwap(_ state: EntityAssociationState, expectedRevision: Int64?, deadline: ContinuousClock.Instant) throws {
        if mode == .conflict { throw EntityAssociationError.conflict }
        guard self.state?.revision == expectedRevision else { throw EntityAssociationError.conflict }
        self.state = state; writes += 1
        if mode == .ambiguousCommit { throw NSError(domain:"private store details",code:1) }
    }
}
private struct AssociationVisionFixture: VisionModel {
    enum Mode: Sendable { case normal, empty, similar, single, dissimilar, noAppearance, renamed }
    let mode: Mode
    let redX: Int
    let identity: VisionIdentity
    init(_ mode: Mode = .normal, redX: Int = 1, version: String = "1") throws {
        self.mode = mode; self.redX = redX
        identity = try VisionIdentity(modelID:"fixture.association",version:version,deployment:.synthetic)
    }
    func detect(_ request: VisionRequest) throws -> VisionOutput {
        var detections: [VisionDetection] = []
        if mode != .empty {
            for i in 0..<(mode == .single ? 1 : 2) {
                let x = mode == .similar ? 1+2*i : i == 0 ? redX : 1
                let y = mode == .similar || i == 0 ? 1 : 5
                let pixels = Data((0..<64).map { x <= $0%8 && $0%8 < x+2 && y <= $0/8 && $0/8 < y+2 ? 1 : 0 })
                detections.append(try VisionDetection(localID:mode == .renamed ? "changed-\(i)" : i == 0 ? "red" : "blue",label:"square",
                    box:PixelBox(x:x,y:y,width:2,height:2),mask:BinaryMask(width:8,height:8,pixels:pixels),confidence:nil,
                    appearance:mode == .noAppearance ? nil : mode == .dissimilar ? [-1,-1] : mode == .similar || i == 0 ? [1,0] : [0,1]))
            }
        }
        return VisionOutput(identity:identity,context:request.context,imageSHA256:request.imageSHA256,detections:detections)
    }
}

// SAFETY: stateless XCTest suite; mutable association state belongs to an actor.
final class EntityAssociationTests: XCTestCase, @unchecked Sendable {
    private static func image(_ index: Int = 0) throws -> Data {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf:root.appendingPathComponent("fixtures/providers/vision-synthetic.v1.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        let frames = try XCTUnwrap(object["frames"] as? [[String:Any]])
        return try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(frames[index]["imageBase64"] as? String)))
    }
    private static func frame(_ mode: AssociationVisionFixture.Mode = .normal, time: Double = 1_700_000_000,
                              actor: UUID, camera: UUID, frameID: UUID = UUID(), image: Int = 0, version: String = "1") async throws -> ImportedFrame {
        let context = try FrameContext(actorID:actor,cameraID:camera,frameID:frameID,
            timestamps:ObservationTimestamps(occurredAt:nil,observedAt:UTCInstant(secondsSince1970:time),recordedAt:UTCInstant(secondsSince1970:time+1),timeZone:IANATimeZone(identifier:"Europe/Paris")))
        return try await FrameImporter(model:AssociationVisionFixture(mode,redX:1+2*image,version:version)).ingest(bytes:Self.image(image),mediaType:"image/png",context:context,
            consent:FrameImportConsent(actorID:actor,cameraID:camera,permitsLocalProcessing:true,permitsCloudTransfer:false,expiresAt:.now.advanced(by:.seconds(20))),deadline:.now.advanced(by:.seconds(3)))
    }
    private static func resolver(_ store: AssociationStoreFixture, policy: AssociationPolicy? = nil) throws -> ContinuityEntityResolver {
        try ContinuityEntityResolver(store:store,policy:policy ?? AssociationPolicy())
    }
    private static func resolve(_ resolver: ContinuityEntityResolver, _ frame: ImportedFrame) async throws -> EntityResolution {
        try await resolver.resolve(frame,deadline:.now.advanced(by:.seconds(3)))
    }
    private static func expect(_ code: EntityAssociationError, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(code)") }
        catch let error as EntityAssociationError { XCTAssertEqual(error,code) }
        catch { XCTFail("Unredacted association failure") }
    }
    func testAnnotatedMovementPreservesEntityIDsAndScoresDespiteChangedLocalIDs() async throws {
        let actor = UUID(), camera = UUID(), store = AssociationStoreFixture(), resolver = try Self.resolver(store)
        let first = try await Self.resolve(resolver,Self.frame(actor:actor,camera:camera))
        XCTAssertEqual(first.assignments.map(\.kind),[.newCandidate,.newCandidate]); XCTAssertTrue(first.synthetic)
        let next = try await Self.resolve(resolver,Self.frame(.renamed,time:1_700_000_001,actor:actor,camera:camera,image:1))
        XCTAssertEqual(next.assignments.map(\.entityID),first.assignments.map(\.entityID))
        XCTAssertEqual(next.assignments.map(\.kind),[.matched,.matched])
        XCTAssertTrue(next.assignments.allSatisfy { ($0.score ?? 0) >= 0.8 })
        XCTAssertEqual(next.context.timestamps.timeZone.identifier,"Europe/Paris")
        XCTAssertNil(next.context.timestamps.occurredAt)
    }
    func testShortOcclusionRestoresIdentityButExpiredContinuityCreatesCandidates() async throws {
        let actor = UUID(), camera = UUID(), store = AssociationStoreFixture(), resolver = try Self.resolver(store)
        let first = try await Self.resolve(resolver,Self.frame(actor:actor,camera:camera))
        let absent = try await Self.resolve(resolver,Self.frame(.empty,time:1_700_000_001,actor:actor,camera:camera,image:1))
        XCTAssertTrue(absent.assignments.isEmpty)
        let seen = try await Self.resolve(resolver,Self.frame(time:1_700_000_002,actor:actor,camera:camera,image:2))
        XCTAssertEqual(seen.assignments.map(\.entityID),first.assignments.map(\.entityID))
        let expired = try await Self.resolve(resolver,Self.frame(time:1_700_000_100,actor:actor,camera:camera))
        XCTAssertTrue(Set(expired.assignments.map(\.entityID)).isDisjoint(with:first.assignments.map(\.entityID)))
        XCTAssertEqual(expired.assignments.map(\.kind),[.newCandidate,.newCandidate])
    }
    func testTwoSimilarObjectsRemainAmbiguousWithRetainedRankedScores() async throws {
        let actor = UUID(), camera = UUID(), store = AssociationStoreFixture(), resolver = try Self.resolver(store)
        let first = try await Self.resolve(resolver,Self.frame(.similar,actor:actor,camera:camera))
        let second = try await Self.resolve(resolver,Self.frame(.similar,time:1_700_000_001,actor:actor,camera:camera))
        XCTAssertEqual(second.assignments.map(\.kind),[.ambiguousCandidate,.ambiguousCandidate])
        XCTAssertTrue(Set(second.assignments.map(\.entityID)).isDisjoint(with:first.assignments.map(\.entityID)))
        for assignment in second.assignments { XCTAssertEqual(assignment.candidates.count,2); XCTAssertEqual(assignment.score,1) }
    }
    func testCompetingDetectionsCannotGreedilyShareOneExistingIdentity() async throws {
        let actor = UUID(), camera = UUID(), store = AssociationStoreFixture(), resolver = try Self.resolver(store)
        let first = try await Self.resolve(resolver,Self.frame(.single,actor:actor,camera:camera))
        let second = try await Self.resolve(resolver,Self.frame(.similar,time:1_700_000_001,actor:actor,camera:camera))
        XCTAssertEqual(second.assignments.map(\.kind),[.ambiguousCandidate,.ambiguousCandidate])
        XCTAssertTrue(second.assignments.allSatisfy { $0.entityID != first.assignments[0].entityID && $0.candidates.count == 1 })
    }
    func testBelowThresholdCreatesSeparateCandidatesAndRetainsLowScores() async throws {
        let actor = UUID(), camera = UUID(), store = AssociationStoreFixture(), resolver = try Self.resolver(store)
        let first = try await Self.resolve(resolver,Self.frame(actor:actor,camera:camera))
        let second = try await Self.resolve(resolver,Self.frame(.dissimilar,time:1_700_000_001,actor:actor,camera:camera))
        XCTAssertEqual(second.assignments.map(\.kind),[.newCandidate,.newCandidate])
        XCTAssertTrue(Set(second.assignments.map(\.entityID)).isDisjoint(with:first.assignments.map(\.entityID)))
        XCTAssertTrue(second.assignments.allSatisfy { $0.candidates.count == 2 && ($0.score ?? 1) < 0.8 })
    }
    func testMissingAppearanceNeverBecomesConfidentContinuityMatch() async throws {
        let actor = UUID(), camera = UUID(), store = AssociationStoreFixture(), resolver = try Self.resolver(store)
        let first = try await Self.resolve(resolver,Self.frame(.noAppearance,actor:actor,camera:camera))
        let second = try await Self.resolve(resolver,Self.frame(.noAppearance,time:1_700_000_001,actor:actor,camera:camera))
        XCTAssertTrue(Set(second.assignments.map(\.entityID)).isDisjoint(with:first.assignments.map(\.entityID)))
        XCTAssertTrue(second.assignments.allSatisfy { $0.score == nil && $0.kind == .newCandidate })
    }
    func testReplayAndNewResolverRestoreSameIDsWithoutAnotherWrite() async throws {
        let actor = UUID(), camera = UUID(), store = AssociationStoreFixture(), frameID = UUID()
        let frame = try await Self.frame(actor:actor,camera:camera,frameID:frameID)
        let first = try await Self.resolve(Self.resolver(store),frame)
        let replay = try await Self.resolve(Self.resolver(store),frame)
        XCTAssertEqual(first,replay)
        let writes = await store.writes; XCTAssertEqual(writes,1)
        let changed = try await Self.frame(.renamed,actor:actor,camera:camera,frameID:frameID)
        await Self.expect(.idempotencyConflict) { _ = try await Self.resolve(Self.resolver(store),changed) }
    }
    func testForeignScopeModelAndOutOfOrderInputsNeverMutateState() async throws {
        let actor = UUID(), camera = UUID(), store = AssociationStoreFixture(), resolver = try Self.resolver(store)
        _ = try await Self.resolve(resolver,Self.frame(actor:actor,camera:camera))
        for frame in [try await Self.frame(actor:UUID(),camera:camera),try await Self.frame(actor:actor,camera:UUID())] {
            await Self.expect(.invalidState) { _ = try await Self.resolve(resolver,frame) }
        }
        let version = try await Self.frame(time:1_700_000_001,actor:actor,camera:camera,version:"2")
        await Self.expect(.incompatibleFrame) { _ = try await Self.resolve(resolver,version) }
        let old = try await Self.frame(time:1_699_999_999,actor:actor,camera:camera)
        await Self.expect(.outOfOrder) { _ = try await Self.resolve(resolver,old) }
        let writes = await store.writes; XCTAssertEqual(writes,1)
    }
    func testCapacityConflictAndAmbiguousCommitDoNotClaimUnpersistedSuccess() async throws {
        let actor = UUID(), camera = UUID(), frame = try await Self.frame(actor:actor,camera:camera)
        let small = AssociationStoreFixture(), policy = try AssociationPolicy(maximumTracks:1)
        await Self.expect(.capacityExceeded) { _ = try await Self.resolve(Self.resolver(small,policy:policy),frame) }
        let writes = await small.writes; XCTAssertEqual(writes,0)
        let conflict = AssociationStoreFixture(.conflict)
        await Self.expect(.conflict) { _ = try await Self.resolve(Self.resolver(conflict),frame) }
        let ambiguous = AssociationStoreFixture(.ambiguousCommit)
        await Self.expect(.unavailable) { _ = try await Self.resolve(Self.resolver(ambiguous),frame) }
        let restored = try await Self.resolve(Self.resolver(ambiguous),frame)
        XCTAssertEqual(restored.assignments.count,2)
        let committed = await ambiguous.writes; XCTAssertEqual(committed,1)
    }
    func testPolicyVersionAndStateValidationAreExplicit() async throws {
        XCTAssertThrowsError(try AssociationPolicy(threshold:.nan))
        XCTAssertThrowsError(try AssociationPolicy(ambiguityMargin:0))
        XCTAssertThrowsError(try AssociationPolicy(maximumTracks:257))
        XCTAssertThrowsError(try AssociationCandidate(entityID:UUID(),score:1.1))
        let actor = UUID(), camera = UUID(), store = AssociationStoreFixture(), frame = try await Self.frame(actor:actor,camera:camera)
        _ = try await Self.resolve(Self.resolver(store),frame)
        let stored = await store.state
        let state = try XCTUnwrap(stored)
        XCTAssertThrowsError(try EntityAssociationState(schemaVersion:2,revision:state.revision,policy:state.policy,width:8,height:8,inputDigest:state.inputDigest,resolution:state.resolution,tracks:state.tracks))
        let changedPolicy = try AssociationPolicy(threshold:0.9)
        await Self.expect(.invalidState) { _ = try await Self.resolve(Self.resolver(store,policy:changedPolicy),frame) }
    }
    func testDeadlineAndExternalCancellationJoinStoreWork() async throws {
        let frame = try await Self.frame(actor:UUID(),camera:UUID()), slow = AssociationStoreFixture(.slow)
        let resolver = try Self.resolver(slow)
        await Self.expect(.timeout) { _ = try await resolver.resolve(frame,deadline:.now.advanced(by:.milliseconds(100))) }
        let cancelled = await slow.cancelled; XCTAssertTrue(cancelled)
        let second = AssociationStoreFixture(.slow), task = Task { try await Self.resolve(Self.resolver(second),frame) }
        try await ContinuousClock().sleep(for:.milliseconds(50)); task.cancel()
        await Self.expect(.cancelled) { _ = try await task.value }
        let secondCancelled = await second.cancelled; XCTAssertTrue(secondCancelled)
    }
}
