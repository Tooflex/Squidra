import Foundation
import PostgresNIO
import SquidraAgentRuntime
import SquidraCognition
import SquidraDomain
import SquidraPostgres
import SquidraProtocols
import SquidraServer
import SquidraWorld
import XCTest

// SAFETY: stateless suite. Every scenario owns actor/run IDs; mutable fixtures are actors.
final class RunWorkerSQLTests: XCTestCase, @unchecked Sendable {
    private static func client() throws -> PostgresClient {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["SQUIDRA_TEST_DB_PORT"].flatMap(Int.init),let password = env["SQUIDRA_TEST_DB_PASSWORD"] else { throw RunEventStoreError.unavailable }
        return try LocalDatabaseConfiguration(port:port,username:"squidra",password:password,database:"squidra").makeClient()
    }
    private static var clock:FixedClock { get throws { try FixedClock(instant:UTCInstant(secondsSince1970:1_700_000_000),timeZone:IANATimeZone(identifier:"UTC")) } }
    private static func request(_ actor:UUID,milliseconds:Int64 = 5000) throws -> ReadRunRequest {
        try ReadRunRequest(actorID:actor,question:"worker lifecycle fixture",planningScope:ReadPlanningScope(entities:[PlanningEntity(id:UUID(),label:"fixture entity")]),
            effectiveToolScope:["world:read"],intent:.current,modelOptions:ReadPlanningOptions(deadline:UTCInstant(secondsSince1970:1_700_000_060)),budget:RunBudget(activeMilliseconds:milliseconds))
    }
    private static func proof(_ request:ReadRunRequest,foreign:Bool = false,foreignScope:Bool = false,foreignIntent:Bool = false) throws -> GroundedAnswer {
        let requestedSubject = try XCTUnwrap(request.planningScope.entities.first?.id)
        let subject = foreignScope ? UUID() : requestedSubject,actor = foreign ? UUID() : request.actorID,at = try clock.now()
        let snapshot = WorldStateSnapshot(actorID:actor,subjectID:subject,validAt:at,knownAt:at,facts:[],projectedThroughSequence:0,availableThroughSequence:0)
        let context = try AnswerEvidenceContext(snapshot:snapshot,expectedActor:actor,intent:foreignIntent ? .historical : request.intent,clock:clock,
            policy:AnswerFreshnessPolicy(maximumObservationAgeSeconds:60,minimumCurrentConfidence:Confidence(0.5)))
        let text = String(decoding:try JSONSerialization.data(withJSONObject:["schemaVersion":"1","claims":[["kind":"unknown","subjectId":subject.uuidString,"citations":[]]]]),as:UTF8.self)
        return try GroundedAnswerValidator().validate(ModelResponse(schemaVersion:"1",requestID:request.requestID,modelID:"worker-lifecycle-fixture",modelVersion:"1",text:text,outputTokens:1,costMicroUSD:0),expectedRequestID:request.requestID,context:context)
    }
    private actor ExecutionFixture: ReadRunAnswerExecuting {
        enum Mode:Sendable { case gated, blocked, foreignProof, foreignScope, foreignIntent }
        let mode:Mode
        var calls = 0,cancellations = 0,released = false
        init(_ mode:Mode) { self.mode = mode }
        func release() { released = true }
        func executeAnswer(_ request:ReadRunRequest) async throws -> GroundedAnswer {
            calls += 1
            do {
                if mode == .blocked { try await Task.sleep(for:.seconds(30)) }
                if mode == .gated { while !released { try await Task.sleep(for:.milliseconds(2)) } }
                try Task.checkCancellation()
                return try RunWorkerSQLTests.proof(request,foreign:mode == .foreignProof,foreignScope:mode == .foreignScope,foreignIntent:mode == .foreignIntent)
            } catch { if Task.isCancelled { cancellations += 1 };throw error }
        }
    }
    private actor PublicationFixture: RunPublicationStore {
        enum Mode:Sendable { case uncertainClaim, misboundClaim, pausedClaim, uncertainFinish }
        let base:any RunPublicationStore,mode:Mode
        var claimsCommitted = 0,finishes = 0,released = false
        init(_ base:any RunPublicationStore,_ mode:Mode) { self.base = base;self.mode = mode }
        func release() { released = true }
        private struct Misbound:RunPublicationClaim { let binding:AGUIRunBinding,executionExpiresAt:UTCInstant }
        func claim(_ binding:AGUIRunBinding,maximumExecutionSeconds:Int,at:UTCInstant,deadline:ContinuousClock.Instant) async throws -> any RunPublicationClaim {
            let claim = try await base.claim(binding,maximumExecutionSeconds:maximumExecutionSeconds,at:at,deadline:deadline)
            claimsCommitted += 1
            if mode == .uncertainClaim { throw RunEventStoreError.unavailable }
            if mode == .misboundClaim {
                return Misbound(binding:AGUIRunBinding(actorID:binding.actorID,runID:UUID(),threadID:binding.threadID,requestID:binding.requestID),executionExpiresAt:claim.executionExpiresAt)
            }
            if mode == .pausedClaim {
                while !released {
                    guard ContinuousClock.now < deadline else { throw RunEventStoreError.timedOut }
                    try await Task.sleep(for:.milliseconds(2))
                }
            }
            return claim
        }
        func finish(_ claim:any RunPublicationClaim,outcome:RunPublicationOutcome,at:UTCInstant,deadline:ContinuousClock.Instant) async throws -> RunPublicationStatus {
            finishes += 1
            let result = try await base.finish(claim,outcome:outcome,at:at,deadline:deadline)
            if mode == .uncertainFinish { throw RunEventStoreError.unavailable }
            return result
        }
        func status(actorID:UUID,runID:UUID,deadline:ContinuousClock.Instant) async throws -> RunPublicationStatus { try await base.status(actorID:actorID,runID:runID,deadline:deadline) }
        func recoverExpired(actorID:UUID,runID:UUID,at:UTCInstant,deadline:ContinuousClock.Instant) async throws -> RunPublicationStatus { try await base.recoverExpired(actorID:actorID,runID:runID,at:at,deadline:deadline) }
    }
    private actor CompletionProbe { var finished = false;func finish() { finished = true } }
    private static func wait(_ predicate:@Sendable () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by:.seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < end else { throw RunEventStoreError.timedOut }
            try await Task.sleep(for:.milliseconds(2))
        }
    }
    private static func phase(_ expected:RunPublicationPhase,_ store:any RunPublicationStore,_ binding:AGUIRunBinding) async throws -> RunPublicationStatus {
        let end = ContinuousClock.now.advanced(by:.seconds(5))
        while ContinuousClock.now < end {
            let status = try await store.status(actorID:binding.actorID,runID:binding.runID,deadline:min(end,.now.advanced(by:.seconds(4))))
            if status.phase == expected { return status }
            try await Task.sleep(for:.milliseconds(10))
        }
        throw RunEventStoreError.timedOut
    }
    private static func withDatabase(_ body:@Sendable (PostgresClient,PostgresClient,UUID) async throws -> Void) async throws {
        let client = try client(),other = try Self.client(),actor = UUID()
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await client.run() };group.addTask { await other.run() };defer { group.cancelAll() }
            try await body(client,other,actor)
        }
    }
    func testCallerCancellationCapacityReplayAndUncertainCompletionNeverRepeatExecution() async throws {
        try await Self.withDatabase { client,other,actor in
            let events = PostgresRunEventStore(client:client,actorID:actor),readback = PostgresRunPublicationStore(client:other,actorID:actor)
            let publication = PublicationFixture(PostgresRunPublicationStore(client:client,actorID:actor),.uncertainFinish),executor = ExecutionFixture(.gated)
            let coordinator = try PublishedReadRunCoordinator(actorID:actor,executor:executor,events:events,publication:publication,clock:Self.clock,maximumConcurrentRuns:1)
            let request = try Self.request(actor),thread = UUID(),channel = AsyncStream<AGUIRunBinding>.makeStream()
            let submitter = Task {
                defer { channel.continuation.finish() }
                channel.continuation.yield(try await coordinator.submit(request,threadID:thread))
                try await Task.sleep(for:.seconds(30))
            }
            do {
                var iterator = channel.stream.makeAsyncIterator()
                let accepted = await iterator.next(),binding = try XCTUnwrap(accepted)
                try await Self.wait { await executor.calls == 1 }
                submitter.cancel();_ = try? await submitter.value
                let callsAfterCallerCancellation = await executor.calls
                XCTAssertEqual(callsAfterCallerCancellation,1)
                do { _ = try await coordinator.submit(Self.request(actor),threadID:UUID());XCTFail("Over-admission") }
                catch { XCTAssertEqual(error as? ReadRunSubmissionError,.busy) }
                for _ in 0..<2 {
                    let status = try await readback.status(actorID:actor,runID:binding.runID,deadline:.now.advanced(by:.seconds(4)))
                    XCTAssertEqual(status.phase,.running)
                    _ = try await events.page(actorID:actor,runID:binding.runID,cursor:nil,limit:32,deadline:.now.advanced(by:.seconds(4)))
                }
                let callsAfterReplay = await executor.calls
                XCTAssertEqual(callsAfterReplay,1)
                await executor.release()
                let status = try await Self.phase(.succeeded,readback,binding)
                XCTAssertEqual(status.stream.nextSequence,7)
                try await Self.wait { await coordinator.activeCount == 0 }
                do { _ = try await coordinator.submit(request,threadID:thread);XCTFail("Duplicate execution") }
                catch { XCTAssertEqual(error as? ReadRunSubmissionError,.conflict) }
                let totalExecutions = await executor.calls
                let totalPublicationAttempts = await publication.finishes
                XCTAssertEqual(totalExecutions,1);XCTAssertEqual(totalPublicationAttempts,1)
            } catch {
                submitter.cancel();_ = try? await submitter.value;await coordinator.shutdown();throw error
            }
            await coordinator.shutdown()
        }
    }
    func testAmbiguousAndMisboundClaimsDispatchNothingAndReleaseCapacity() async throws {
        try await Self.withDatabase { client,_,actor in
            let events = PostgresRunEventStore(client:client,actorID:actor),base = PostgresRunPublicationStore(client:client,actorID:actor)
            for mode in [PublicationFixture.Mode.uncertainClaim,.misboundClaim] {
                let publication = PublicationFixture(base,mode),executor = ExecutionFixture(.gated),request = try Self.request(actor)
                let coordinator = try PublishedReadRunCoordinator(actorID:actor,executor:executor,events:events,publication:publication,clock:Self.clock)
                do { _ = try await coordinator.submit(request,threadID:UUID());XCTFail("Bad claim accepted") }
                catch { XCTAssertEqual(error as? ReadRunSubmissionError,.recoveryRequired) }
                let executionsAfterBadClaim = await executor.calls
                let reservationsAfterBadClaim = await coordinator.activeCount
                XCTAssertEqual(executionsAfterBadClaim,0);XCTAssertEqual(reservationsAfterBadClaim,0)
                let status = try await base.status(actorID:actor,runID:request.runID,deadline:.now.advanced(by:.seconds(4)))
                XCTAssertEqual(status.phase,.running);XCTAssertEqual(status.stream.nextSequence,2)
                await coordinator.shutdown()
            }
        }
    }
    func testShutdownJoinsSubmissionStillWaitingForItsClaim() async throws {
        try await Self.withDatabase { client,other,actor in
            let events = PostgresRunEventStore(client:client,actorID:actor),base = PostgresRunPublicationStore(client:client,actorID:actor)
            let publication = PublicationFixture(base,.pausedClaim),executor = ExecutionFixture(.gated),request = try Self.request(actor)
            let coordinator = try PublishedReadRunCoordinator(actorID:actor,executor:executor,events:events,publication:publication,clock:Self.clock)
            let submitter = Task { try await coordinator.submit(request,threadID:UUID()) }
            try await Self.wait { await publication.claimsCommitted == 1 }
            let probe = CompletionProbe(),shutdown = Task { await coordinator.shutdown();await probe.finish() }
            try await Self.wait { !(await coordinator.isAccepting) }
            let shutdownFinishedBeforeRelease = await probe.finished
            let executionsBeforeRelease = await executor.calls
            XCTAssertFalse(shutdownFinishedBeforeRelease);XCTAssertEqual(executionsBeforeRelease,0)
            await publication.release()
            do { _ = try await submitter.value;XCTFail("Shutdown accepted a worker") }
            catch { XCTAssertEqual(error as? ReadRunSubmissionError,.closed) }
            await shutdown.value
            let shutdownFinishedAfterRelease = await probe.finished
            let activeAfterShutdown = await coordinator.activeCount
            let executionsAfterShutdown = await executor.calls
            XCTAssertTrue(shutdownFinishedAfterRelease);XCTAssertEqual(activeAfterShutdown,0);XCTAssertEqual(executionsAfterShutdown,0)
            let status = try await PostgresRunPublicationStore(client:other,actorID:actor).status(actorID:actor,runID:request.runID,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(status.phase,.cancelled)
        }
    }
    func testDeadlineShutdownCancellationAndForeignGroundingHaveFixedOutcomes() async throws {
        try await Self.withDatabase { client,other,actor in
            let events = PostgresRunEventStore(client:client,actorID:actor),publication = PostgresRunPublicationStore(client:client,actorID:actor),readback = PostgresRunPublicationStore(client:other,actorID:actor)
            for scenario in 0..<5 {
                let modes:[ExecutionFixture.Mode] = [.blocked,.blocked,.foreignProof,.foreignScope,.foreignIntent]
                let executor = ExecutionFixture(modes[scenario]),request = try Self.request(actor,milliseconds:scenario == 0 ? 50 : 5000)
                let coordinator = try PublishedReadRunCoordinator(actorID:actor,executor:executor,events:events,publication:publication,clock:Self.clock)
                do {
                    let binding = try await coordinator.submit(request,threadID:UUID())
                    try await Self.wait { await executor.calls == 1 }
                    if scenario == 1 { await coordinator.shutdown() }
                    let status = try await Self.phase(scenario == 1 ? .cancelled : .failed,readback,binding)
                    XCTAssertEqual(status.stream.nextSequence,3)
                    let page = try await events.page(actorID:actor,runID:binding.runID,cursor:nil,limit:32,deadline:.now.advanced(by:.seconds(4)))
                    XCTAssertEqual(page.records.count,2)
                    if scenario != 1 {
                        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:page.records[1].json) as? [String:Any])
                        XCTAssertEqual(object["code"] as? String,scenario == 0 ? AGUIPublicFailure.deadlineExceeded.rawValue : AGUIPublicFailure.executionFailed.rawValue)
                    }
                    let executionCount = await executor.calls
                    XCTAssertEqual(executionCount,1)
                } catch { await coordinator.shutdown();throw error }
                await coordinator.shutdown()
                let cancellationCount = await executor.cancellations
                if scenario < 2 { XCTAssertEqual(cancellationCount,1) }
            }
        }
    }
}
