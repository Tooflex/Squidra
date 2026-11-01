import Foundation
import PostgresNIO
import SquidraAgentRuntime
import SquidraCognition
import SquidraDomain
import SquidraPostgres
import SquidraProtocols
@testable import SquidraServer
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
    func testDurableLocalOwnershipPrecedesDispatchAndRejectsCopiedDomain() async throws {
        try await Self.withDatabase { client,other,actor in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("squidra-owner-sql-"+UUID().uuidString)
            let copyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("squidra-owner-copy-"+UUID().uuidString)
            for path in [directory,copyDirectory] { try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]) }
            defer { try? FileManager.default.removeItem(at:directory);try? FileManager.default.removeItem(at:copyDirectory) }
            let owner = try LocalRunOwnership.acquire(directory:directory,actorID:actor)
            defer { owner.releaseAfterJoiningWorkers() }
            let ownership = PostgresReadRunOwnershipStore(client:client,ownership:owner)
            async let firstBind:Void = ownership.bind(deadline:.now.advanced(by:.seconds(4)))
            async let secondBind:Void = PostgresReadRunOwnershipStore(client:other,ownership:owner).bind(deadline:.now.advanced(by:.seconds(4)))
            _ = try await (firstBind,secondBind)
            let events = PostgresRunEventStore(client:client,actorID:actor),publication = PostgresRunPublicationStore(client:client,actorID:actor)
            let tasks = PostgresReadRunTaskStore(client:client,actorID:actor),executor = ExecutionFixture(.blocked)
            let coordinator = try PublishedReadRunCoordinator(actorID:actor,executor:executor,events:events,publication:publication,
                clock:Self.clock,tasks:tasks,ownership:ownership)
            let request = try Self.request(actor)
            _ = try await coordinator.submit(request,threadID:UUID())
            try await Self.wait { await executor.calls == 1 }
            let rows = try await other.query("SELECT owner_id,domain_id,file_id FROM read_run_owners WHERE actor_id=\(actor) AND run_id=\(request.runID)").collect()
            let row = try XCTUnwrap(rows.first),(id,domain,file) = try row.decode((UUID,UUID,String).self)
            XCTAssertEqual(id,owner.ownerID);XCTAssertEqual(domain,owner.domainID);XCTAssertEqual(file,owner.fileID)
            // An acknowledgement retry remains exact even after publication starts.
            try await ownership.register(runID:request.runID,deadline:.now.advanced(by:.seconds(4)))
            let name = actor.uuidString.lowercased()+".lock"
            try FileManager.default.copyItem(at:directory.appendingPathComponent(name),to:copyDirectory.appendingPathComponent(name))
            let copy = try LocalRunOwnership.acquire(directory:copyDirectory,actorID:actor)
            defer { copy.releaseAfterJoiningWorkers() }
            XCTAssertEqual(copy.domainID,owner.domainID);XCTAssertNotEqual(copy.fileID,owner.fileID)
            let wrongStore = PostgresReadRunOwnershipStore(client:other,ownership:copy),never = ExecutionFixture(.blocked)
            let rejected = try PublishedReadRunCoordinator(actorID:actor,executor:never,events:events,publication:publication,clock:Self.clock,tasks:tasks,ownership:wrongStore)
            do { _ = try await rejected.submit(Self.request(actor),threadID:UUID());XCTFail("Copied domain dispatched") }
            catch { XCTAssertEqual(error as? ReadRunSubmissionError,.recoveryRequired) }
            let deniedCalls = await never.calls;XCTAssertEqual(deniedCalls,0)
            await rejected.shutdown()
            // A run claimed before worker start belongs to the original owner too.
            let interrupted = try Self.request(actor),binding = AGUIRunBinding(actorID:actor,runID:interrupted.runID,threadID:UUID(),requestID:interrupted.requestID)
            _ = try await events.create(binding,retentionSeconds:3600,deadline:.now.advanced(by:.seconds(4)))
            try await tasks.save(StoredReadRunTask(request:interrupted,threadID:binding.threadID),deadline:.now.advanced(by:.seconds(4)))
            try await ownership.register(runID:interrupted.runID,deadline:.now.advanced(by:.seconds(4)))
            let originalClaim = try await publication.claim(binding,maximumExecutionSeconds:180,at:Self.clock.now(),deadline:.now.advanced(by:.seconds(4)))
            let legacy = try Self.request(actor),legacyBinding = AGUIRunBinding(actorID:actor,runID:legacy.runID,threadID:UUID(),requestID:legacy.requestID)
            _ = try await events.create(legacyBinding,retentionSeconds:3600,deadline:.now.advanced(by:.seconds(4)))
            try await tasks.save(StoredReadRunTask(request:legacy,threadID:legacyBinding.threadID),deadline:.now.advanced(by:.seconds(4)))
            _ = try await publication.claim(legacyBinding,maximumExecutionSeconds:5,at:Self.clock.now(),deadline:.now.advanced(by:.seconds(4)))
            for invalidOwner in [owner,copy] {
                do { _ = try await publication.takeOver(runID:interrupted.runID,ownership:invalidOwner,deadline:.now.advanced(by:.seconds(4)));XCTFail("Live or copied owner took over") }
                catch { XCTAssertEqual(error as? RunEventStoreError,.conflict) }
            }
            // An untracked legacy run is not eligible even for the same actor.
            let before = try await ownership.previousRuns(deadline:.now.advanced(by:.seconds(4)))
            XCTAssertTrue(before.isEmpty)
            await coordinator.shutdown()
            owner.releaseAfterJoiningWorkers()
            do { try await ownership.register(runID:interrupted.runID,deadline:.now.advanced(by:.seconds(4)));XCTFail("Released handle accepted") }
            catch { XCTAssertEqual(error as? ReadRunTaskError,.invalidState) }
            let next = try LocalRunOwnership.acquire(directory:directory,actorID:actor)
            defer { next.releaseAfterJoiningWorkers() }
            let resumedStore = PostgresReadRunOwnershipStore(client:other,ownership:next)
            let candidates = try await resumedStore.previousRuns(limit:1,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(candidates.map(\.runID),[interrupted.runID]);XCTAssertEqual(candidates.first?.ownerID,owner.ownerID)
            do { _ = try await publication.takeOver(runID:legacy.runID,ownership:next,deadline:.now.advanced(by:.seconds(4)));XCTFail("Unregistered run taken over") }
            catch { XCTAssertEqual(error as? RunEventStoreError,.conflict) }
            let transferred = try await publication.takeOver(runID:interrupted.runID,ownership:next,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(transferred.binding,originalClaim.binding)
            XCTAssertEqual(transferred.executionExpiresAt,originalClaim.executionExpiresAt)
            do { _ = try await publication.takeOver(runID:interrupted.runID,ownership:next,deadline:.now.advanced(by:.seconds(4)));XCTFail("Second dispatch claim issued") }
            catch { XCTAssertEqual(error as? RunEventStoreError,.conflict) }
            do { _ = try await publication.finish(originalClaim,outcome:.cancelled,at:Self.clock.now(),deadline:.now.advanced(by:.seconds(4)));XCTFail("Old claim published") }
            catch { XCTAssertEqual(error as? RunEventStoreError,.conflict) }
            let exhausted = try Self.request(actor),exhaustedBinding = AGUIRunBinding(actorID:actor,runID:exhausted.runID,threadID:UUID(),requestID:exhausted.requestID)
            _ = try await events.create(exhaustedBinding,retentionSeconds:3600,deadline:.now.advanced(by:.seconds(4)))
            try await tasks.save(StoredReadRunTask(request:exhausted,threadID:exhaustedBinding.threadID),deadline:.now.advanced(by:.seconds(4)))
            try await resumedStore.register(runID:exhausted.runID,deadline:.now.advanced(by:.seconds(4)))
            _ = try await publication.claim(exhaustedBinding,maximumExecutionSeconds:180,at:Self.clock.now(),deadline:.now.advanced(by:.seconds(4)))
            // Publication grace remains live, but the execution budget has expired.
            _ = try await other.query("UPDATE run_event_streams SET execution_lease_until=clock_timestamp()+interval '4 seconds' WHERE actor_id=\(actor) AND run_id=\(exhausted.runID)").collect()
            // Releasing ownership revokes this capability even while its DB lease is live.
            next.releaseAfterJoiningWorkers()
            do { _ = try await publication.finish(transferred,outcome:.cancelled,at:Self.clock.now(),deadline:.now.advanced(by:.seconds(4)));XCTFail("Released claim published") }
            catch { XCTAssertEqual(error as? RunEventStoreError,.conflict) }
            let third = try LocalRunOwnership.acquire(directory:directory,actorID:actor)
            defer { third.releaseAfterJoiningWorkers() }
            do { _ = try await publication.takeOver(runID:exhausted.runID,ownership:third,deadline:.now.advanced(by:.seconds(4)));XCTFail("Expired execution budget renewed") }
            catch { XCTAssertEqual(error as? RunEventStoreError,.conflict) }
            let finalClaim = try await publication.takeOver(runID:interrupted.runID,ownership:third,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(finalClaim.executionExpiresAt,originalClaim.executionExpiresAt)
            let finished = try await publication.finish(finalClaim,outcome:.cancelled,at:Self.clock.now(),deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(finished.phase,.cancelled);XCTAssertEqual(finished.stream.nextSequence,3)
            do { _ = try await publication.takeOver(runID:interrupted.runID,ownership:third,deadline:.now.advanced(by:.seconds(4)));XCTFail("Terminal publication taken over") }
            catch { XCTAssertEqual(error as? RunEventStoreError,.conflict) }
            do { try await PostgresReadRunOwnershipStore(client:other,ownership:third).register(runID:interrupted.runID,deadline:.now.advanced(by:.seconds(4)));XCTFail("Old registration overwritten") }
            catch { XCTAssertEqual(error as? ReadRunTaskError,.conflict) }
            do { _ = try await other.query("DELETE FROM read_run_local_domains WHERE actor_id=\(actor)").collect();XCTFail("Local domain deleted") }
            catch { XCTAssertEqual((error as? PSQLError)?.serverInfo?[.sqlState],"55000") }
            do { _ = try await other.query("UPDATE read_run_owners SET owner_id=\(next.ownerID) WHERE actor_id=\(actor) AND run_id=\(interrupted.runID)").collect();XCTFail("Run owner replaced") }
            catch { XCTAssertEqual((error as? PSQLError)?.serverInfo?[.sqlState],"55000") }
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
    func testRecoveryClaimSharesCapacityAndShutdownJoinsWithoutDispatch() async throws {
        try await Self.withDatabase { client,other,actor in
            let events = PostgresRunEventStore(client:client,actorID:actor),base = PostgresRunPublicationStore(client:client,actorID:actor)
            let publication = PublicationFixture(base,.pausedClaim),executor = ExecutionFixture(.gated),request = try Self.request(actor)
            let coordinator = try PublishedReadRunCoordinator(actorID:actor,executor:executor,events:events,publication:publication,clock:Self.clock,maximumConcurrentRuns:1)
            let binding = AGUIRunBinding(actorID:actor,runID:request.runID,threadID:UUID(),requestID:request.requestID)
            _ = try await events.create(binding,retentionSeconds:3600,deadline:.now.advanced(by:.seconds(4)))
            let recovery = Task {
                try await coordinator.recover(StoredReadRunTask(request:request,threadID:binding.threadID),claim:{
                    try await publication.claim(binding,maximumExecutionSeconds:5,at:Self.clock.now(),deadline:.now.advanced(by:.seconds(4)))
                },execute:{ request in _ = try await executor.executeAnswer(request) },complete:{ XCTFail("Unexecuted recovery finalized") })
            }
            try await Self.wait { await publication.claimsCommitted == 1 }
            do { _ = try await coordinator.submit(Self.request(actor),threadID:UUID());XCTFail("Recovery reservation exceeded capacity") }
            catch { XCTAssertEqual(error as? ReadRunSubmissionError,.busy) }
            let probe = CompletionProbe(),shutdown = Task { await coordinator.shutdown();await probe.finish() }
            try await Self.wait { !(await coordinator.isAccepting) }
            let early = await probe.finished;XCTAssertFalse(early)
            await publication.release()
            let admitted = try await recovery.value;XCTAssertFalse(admitted)
            await shutdown.value
            let calls = await executor.calls,active = await coordinator.activeCount
            XCTAssertEqual(calls,0);XCTAssertEqual(active,0)
            let status = try await PostgresRunPublicationStore(client:other,actorID:actor).status(actorID:actor,runID:request.runID,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(status.phase,.cancelled)
        }
    }
    func testTargetedCancellationDuringClaimNeverDispatchesAndPreservesAdmission() async throws {
        try await Self.withDatabase { client,_,actor in
            let events = PostgresRunEventStore(client:client,actorID:actor),base = PostgresRunPublicationStore(client:client,actorID:actor)
            let publication = PublicationFixture(base,.pausedClaim),executor = ExecutionFixture(.gated),request = try Self.request(actor)
            let coordinator = try PublishedReadRunCoordinator(actorID:actor,executor:executor,events:events,publication:publication,clock:Self.clock)
            let submitter = Task { try await coordinator.submit(request,threadID:UUID()) }
            try await Self.wait { await publication.claimsCommitted == 1 }
            do { _ = try await coordinator.requestCancellation(actorID:UUID(),runID:request.runID);XCTFail("Foreign cancellation") }
            catch { XCTAssertEqual(error as? ReadRunSubmissionError,.invalidRequest) }
            let accepted = try await coordinator.requestCancellation(actorID:actor,runID:request.runID)
            XCTAssertTrue(accepted)
            await publication.release()
            do { _ = try await submitter.value;XCTFail("Cancelled claim dispatched") }
            catch { XCTAssertEqual(error as? ReadRunSubmissionError,.cancelled) }
            let status = try await base.status(actorID:actor,runID:request.runID,deadline:.now.advanced(by:.seconds(4)))
            XCTAssertEqual(status.phase,.cancelled)
            let calls = await executor.calls,accepting = await coordinator.isAccepting
            XCTAssertEqual(calls,0);XCTAssertTrue(accepting)
            let repeated = try await coordinator.requestCancellation(actorID:actor,runID:request.runID)
            XCTAssertFalse(repeated)
            await coordinator.shutdown()
        }
    }
    func testTargetedCancellationReachesWorkerAndDurableTerminalState() async throws {
        try await Self.withDatabase { client,other,actor in
            let events = PostgresRunEventStore(client:client,actorID:actor),publication = PostgresRunPublicationStore(client:client,actorID:actor)
            let executor = ExecutionFixture(.blocked),request = try Self.request(actor)
            let coordinator = try PublishedReadRunCoordinator(actorID:actor,executor:executor,events:events,publication:publication,clock:Self.clock)
            let binding = try await coordinator.submit(request,threadID:UUID())
            try await Self.wait { await executor.calls == 1 }
            let accepted = try await coordinator.requestCancellation(actorID:actor,runID:request.runID)
            XCTAssertTrue(accepted)
            let status = try await Self.phase(.cancelled,PostgresRunPublicationStore(client:other,actorID:actor),binding)
            XCTAssertTrue(status.stream.isTerminal)
            try await Self.wait { await coordinator.activeCount == 0 }
            let cancellations = await executor.cancellations,accepting = await coordinator.isAccepting
            XCTAssertEqual(cancellations,1);XCTAssertTrue(accepting)
            await coordinator.shutdown()
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
