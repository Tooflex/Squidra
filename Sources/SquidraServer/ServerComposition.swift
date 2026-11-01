import Foundation
import Hummingbird
import Logging
import SquidraAgentRuntime
import SquidraCognition
import SquidraObservability
import SquidraProtocols
import SquidraPostgres
import SquidraDomain
import SquidraSecurity
import SquidraTemporal
import SquidraTools
import SquidraMemory
import PostgresNIO

/// Composition owns dependencies per application. No global runtime or store.
enum ServerComposition {
    static func live(configuration: ServerConfiguration, readHost: ReadHostConfiguration? = nil, traceRecorder: PrivateTraceRecorder? = nil, localOwnership: LocalRunOwnership? = nil) throws -> some ApplicationProtocol {
        if let localOwnership {
            guard localOwnership.isHeld,localOwnership.actorID == configuration.boundary.actorID else { throw ReadRunTaskError.invalidState }
        }
        let recorder = try traceRecorder ?? PrivateTraceRecorder(limits:TraceLimits())
        let client = configuration.database.makeClient()
        let ownershipStore = localOwnership.map { PostgresReadRunOwnershipStore(client:client,ownership:$0) }
        let readiness = PostgresSchemaReadiness(client: client)
        let approvals = ApprovalCoordinator(store:PostgresApprovalStore(client:client),clock:SystemClock(timeZone:try! IANATimeZone(identifier:"Etc/UTC")))
        let world = PostgresLocationProjection(actorID:configuration.boundary.actorID,client:client)
        let frameImports = try configuration.syntheticImport.map { FrameImportRoutes(ingestion:try PostgresFrameIngestion(client:client,model:$0.model,policy:$0.policy)) }
        let worldReads = try WorldReadRoutes(actorID:configuration.boundary.actorID,world:world,changes:world)
        let recovery = WorldProjectionRecovery(actorID:configuration.boundary.actorID,
            repository:PostgresWorldRepository(client:client),projector:world)
        let watches = PostgresIntentionStore(actorID: configuration.boundary.actorID,client: client)
        let events = PostgresRunEventStore(client:client,actorID:configuration.boundary.actorID)
        let publication = PostgresRunPublicationStore(client:client,actorID:configuration.boundary.actorID)
        let runtime = PostgresRunStore(client:client)
        let submission:RunRoutes.Submission?
        let continuationStep: (@Sendable () async throws -> Bool)?
        if let readHost {
            let imported: PostgresImportedEntityReadScope?
            if readHost.allowSyntheticImportedEntities {
                guard let profile = configuration.syntheticImport else { throw ReadRunSubmissionError.invalidRequest }
                imported = PostgresImportedEntityReadScope(client:client,policy:profile.policy)
            } else { imported = nil }
            let entityScope = ReadHostEntityScope(entities:readHost.entities,imported:imported)
            let clock = try SystemClock(timeZone:IANATimeZone(identifier:"Etc/UTC"))
            let router = try ModelRouter(models:readHost.models.map { TracedLanguageModel($0) },clock:clock)
            let queries = TracedWorldQueries(state:world,changes:world)
            let registrations = try [WorldLocationTool(world:queries).registration(),WorldChangesTool(world:queries).registration()]
            let gateway = try ActionGateway(tools:registrations.map { $0.decoratingExecutor { TracedToolExecutor($0) } },
                policy:ScopedServerWorldReadPolicy(actorID:configuration.boundary.actorID,scope:entityScope))
            let engine = try ReadRunEngine(router:router,gateway:gateway,store:runtime,clock:clock,freshness:readHost.freshness,completions:PostgresReadRunCompletionStore(client:client,actorID:configuration.boundary.actorID),plans:PostgresReadRunPlanStore(client:client,actorID:configuration.boundary.actorID),toolResults:PostgresReadRunToolResultStore(client:client,actorID:configuration.boundary.actorID),answers:PostgresReadRunAnswerStore(client:client,actorID:configuration.boundary.actorID))
            let coordinator = try PublishedReadRunCoordinator(actorID:configuration.boundary.actorID,executor:TracedReadExecutor(base:engine,recorder:recorder),
                events:events,publication:publication,clock:clock,tasks:PostgresReadRunTaskStore(client:client,actorID:configuration.boundary.actorID),ownership:ownershipStore)
            submission = try RunRoutes.Submission(coordinator:coordinator,clock:clock,entities:readHost.entities,budget:readHost.budget,resolveEntity:{ try await entityScope.resolve($0,deadline:$1) })
            if let ownershipStore,let localOwnership {
                let tasks = PostgresReadRunTaskStore(client:client,actorID:configuration.boundary.actorID)
                continuationStep = {
                    for candidate in try await ownershipStore.previousRuns(continuableOnly:true,deadline:.now.advanced(by:.seconds(4))) {
                        guard let task = try await tasks.load(runID:candidate.runID,deadline:.now.advanced(by:.seconds(4))) else { continue }
                        let snapshot: RunSnapshot?
                        do { snapshot = try await runtime.load(actorID:candidate.actorID,runID:candidate.runID,deadline:.now.advanced(by:.seconds(4))) }
                        catch RunStoreError.notFound { snapshot = nil }
                        guard snapshot?.state.isTerminal != true else { continue }
                        do {
                            if try await coordinator.recover(task,claim:{
                                try await publication.takeOver(runID:candidate.runID,ownership:localOwnership,deadline:.now.advanced(by:.seconds(4)))
                            },execute:{ request in
                                let correlation = try TraceCorrelation(traceID:request.traceID,runID:request.runID,taskID:request.requestID)
                                try await recorder.withTrace(correlation) { session in
                                    if let usage = try? TraceUsage(requestID:request.requestID) { await session.recordUsage(usage) }
                                    guard !request.planningScope.allowGlobalChanges else { throw ReadRunFailureCode.recoveryRequired }
                                    for entity in request.planningScope.entities {
                                        guard try await entityScope.resolve(entity.id,deadline:.now.advanced(by:.seconds(4))) != nil else { throw ReadRunFailureCode.recoveryRequired }
                                    }
                                    // The engine persists its initial runtime before any model/read call.
                                    // Missing runtime after a proved stopped admission is first execution.
                                    guard let snapshot else { _ = try await engine.executeAnswer(request);return }
                                    switch snapshot.state {
                                    case .created,.validating,.contextLoading: _ = try await engine.resumeBeforePlanning(request,expectedVersion:snapshot.version)
                                    case .planning: _ = try await engine.resumeSavedPlan(request,expectedVersion:snapshot.version)
                                    case .executingTool: _ = try await engine.resumeSavedToolResult(request,expectedVersion:snapshot.version)
                                    case .responding: _ = try await engine.resumeSavedAnswer(request,expectedVersion:snapshot.version)
                                    default: throw ReadRunFailureCode.recoveryRequired
                                    }
                                }
                            },complete:{
                                _ = try await publication.recoverCompleted(runID:candidate.runID,ownership:localOwnership,
                                    at:clock.now(),deadline:.now.advanced(by:.seconds(4)))
                            }) { return true }
                        } catch RunEventStoreError.conflict { continue }
                    }
                    return false
                }
            } else { continuationStep = nil }
        } else { submission = nil;continuationStep = nil }
        return application(configuration: configuration, readiness: { try await readiness.check() }, client: client,
            approvals:approvals,ledger:PostgresActionLedger(client:client),worldReads:worldReads,frameImports:frameImports,
            consolidation:PostgresConsolidationStore(client:client,actorID:configuration.boundary.actorID),
            runs:try! RunRoutes.Dependencies(actorID:configuration.boundary.actorID,
                events:events,publication:publication,runtime:runtime,submission:submission,traces:recorder),
            beforeServing:{
                if let profile = configuration.syntheticImport {
                    let policy = profile.policy
                    let rows = try await client.query("SELECT EXISTS(SELECT 1 FROM world_entities WHERE id=\(policy.locationID) AND actor_id=\(policy.actorID)) AND EXISTS(SELECT 1 FROM coordinate_frames WHERE id=\(policy.coordinateFrameID) AND actor_id=\(policy.actorID))").collect()
                    guard let row = rows.first,try row.decode(Bool.self) else { throw FramePublicationError.scopeMismatch }
                }
                try await ownershipStore?.bind(deadline:.now.advanced(by:.seconds(4)))
                _ = try await recovery.recover()
            },localOwnership:localOwnership,
            publicationStep: {
                if let ownershipStore,let localOwnership {
                    let candidates = try await ownershipStore.previousRuns(completedOnly:true,deadline:.now.advanced(by:.seconds(4)))
                    for candidate in candidates {
                        if try await publication.recoverCompleted(runID:candidate.runID,ownership:localOwnership,
                            at:UTCInstant(secondsSince1970:Date().timeIntervalSince1970),deadline:.now.advanced(by:.seconds(4))) { return true }
                    }
                }
                if try await continuationStep?() == true { return true }
                return try await publication.recoverNextCompleted(at:UTCInstant(secondsSince1970:Date().timeIntervalSince1970),deadline:.now.advanced(by:.seconds(4)))
            },
            watchStep: {
                let progressed = try await watches.processNext(deadline: .now.advanced(by: .seconds(4)))
                if progressed { _ = try await recovery.recover() }
                return progressed
            })
    }

    static func application(configuration: ServerConfiguration,
                            readiness: @escaping @Sendable () async throws -> DatabaseReadiness,
                            client: PostgresClient? = nil, approvals: ApprovalCoordinator? = nil, ledger: (any ActionLedgerStore)? = nil,
                            worldReads: WorldReadRoutes? = nil, frameImports: FrameImportRoutes? = nil, consolidation: (any ConsolidationStore)? = nil, runs: RunRoutes.Dependencies? = nil,
                            beforeServing: (@Sendable () async throws -> Void)? = nil,
                            localOwnership: LocalRunOwnership? = nil,
                            publicationStep: (@Sendable () async throws -> Bool)? = nil,
                            watchStep: (@Sendable () async throws -> Bool)? = nil) -> some ApplicationProtocol {
        let router = Router(context: BoundaryContext.self)
        for path in ["/health/live", "/health"] {
            router.get(RouterPath(path)) { _, _ in json(.ok, "{\"status\":\"alive\"}") }
        }
        for path in ["/health/ready", "/ready"] {
            router.get(RouterPath(path)) { _, _ in
                switch try await readiness() {
                case .ready: return json(.ok, "{\"status\":\"ready\"}")
                case .notReady(let failure):
                    return json(.serviceUnavailable, "{\"status\":\"not_ready\",\"dependency\":\"\(failure.rawValue)\"}")
                }
            }
        }
        if let approvals,let ledger { ApprovalRoutes.mount(router,approvals:approvals,ledger:ledger) }
        if let consolidation { ConsolidationRoutes.mount(router,store:consolidation) }
        worldReads?.mount(router)
        frameImports?.mount(router)
        RunRoutes.mount(router,dependencies:runs)
        var app = Application(responder: HTTPBoundary(inner: router.buildResponder(), configuration: configuration.boundary),
            server: .http1(configuration: .init(idleTimeout: .seconds(30))),
            configuration: .init(address: .hostname(configuration.boundary.listenHost, port: configuration.port), reuseAddress: false),
            onServerRunning: { channel in
                if let port = channel.localAddress?.port {
                    FileHandle.standardOutput.write(Data("SQUIDRA listening 127.0.0.1:\(port)\n".utf8))
                }
            },
            logger: Logger(label: "squidra.server", factory: { _ in SwiftLogNoOpLogHandler() }))
        if let client { app.addServices(client) }
        if let watchStep { app.addServices(WatchWorkerService(processNext: watchStep)) }
        if runs?.submission?.coordinator != nil || localOwnership != nil {
            app.addServices(ReadWorkerService(coordinator:runs?.submission?.coordinator,ownership:localOwnership,recovery:publicationStep))
        } else if let publicationStep { app.addServices(PublicationRecoveryService(processNext:publicationStep)) }
        if let beforeServing { app.beforeServerStarts(perform:beforeServing) }
        return app
    }

    private static func json(_ status: HTTPResponse.Status, _ body: String) -> Response {
        Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(string: body)))
    }
}
