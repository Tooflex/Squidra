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
import PostgresNIO

/// Composition owns dependencies per application. No global runtime or store.
enum ServerComposition {
    static func live(configuration: ServerConfiguration, readHost: ReadHostConfiguration? = nil, traceRecorder: PrivateTraceRecorder? = nil) throws -> some ApplicationProtocol {
        let recorder = try traceRecorder ?? PrivateTraceRecorder(limits:TraceLimits())
        let client = configuration.database.makeClient()
        let readiness = PostgresSchemaReadiness(client: client)
        let approvals = ApprovalCoordinator(store:PostgresApprovalStore(client:client),clock:SystemClock(timeZone:try! IANATimeZone(identifier:"Etc/UTC")))
        let world = PostgresLocationProjection(actorID:configuration.boundary.actorID,client:client)
        let worldReads = try WorldReadRoutes(actorID:configuration.boundary.actorID,world:world,changes:world)
        let recovery = WorldProjectionRecovery(actorID:configuration.boundary.actorID,
            repository:PostgresWorldRepository(client:client),projector:world)
        let watches = PostgresIntentionStore(actorID: configuration.boundary.actorID,client: client)
        let events = PostgresRunEventStore(client:client,actorID:configuration.boundary.actorID)
        let publication = PostgresRunPublicationStore(client:client,actorID:configuration.boundary.actorID)
        let runtime = PostgresRunStore(client:client)
        let submission:RunRoutes.Submission?
        if let readHost {
            let clock = try SystemClock(timeZone:IANATimeZone(identifier:"Etc/UTC"))
            let router = try ModelRouter(models:readHost.models.map { TracedLanguageModel($0) },clock:clock)
            let queries = TracedWorldQueries(state:world,changes:world)
            let registrations = try [WorldLocationTool(world:queries).registration(),WorldChangesTool(world:queries).registration()]
            let gateway = try ActionGateway(tools:registrations.map { $0.decoratingExecutor { TracedToolExecutor($0) } },
                policy:ServerWorldReadPolicy(actorID:configuration.boundary.actorID,entities:readHost.entities))
            let engine = try ReadRunEngine(router:router,gateway:gateway,store:runtime,clock:clock,freshness:readHost.freshness,completions:PostgresReadRunCompletionStore(client:client,actorID:configuration.boundary.actorID))
            let coordinator = try PublishedReadRunCoordinator(actorID:configuration.boundary.actorID,executor:TracedReadExecutor(base:engine,recorder:recorder),
                events:events,publication:publication,clock:clock,tasks:PostgresReadRunTaskStore(client:client,actorID:configuration.boundary.actorID))
            submission = try RunRoutes.Submission(coordinator:coordinator,clock:clock,entities:readHost.entities,budget:readHost.budget)
        } else { submission = nil }
        return application(configuration: configuration, readiness: { try await readiness.check() }, client: client,
            approvals:approvals,ledger:PostgresActionLedger(client:client),worldReads:worldReads,
            runs:try! RunRoutes.Dependencies(actorID:configuration.boundary.actorID,
                events:events,publication:publication,runtime:runtime,submission:submission,traces:recorder),
            beforeServing:{ _ = try await recovery.recover() },
            watchStep: {
                let progressed = try await watches.processNext(deadline: .now.advanced(by: .seconds(4)))
                if progressed { _ = try await recovery.recover() }
                return progressed
            })
    }

    static func application(configuration: ServerConfiguration,
                            readiness: @escaping @Sendable () async throws -> DatabaseReadiness,
                            client: PostgresClient? = nil, approvals: ApprovalCoordinator? = nil, ledger: (any ActionLedgerStore)? = nil,
                            worldReads: WorldReadRoutes? = nil, runs: RunRoutes.Dependencies? = nil,
                            beforeServing: (@Sendable () async throws -> Void)? = nil,
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
        worldReads?.mount(router)
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
        if let coordinator = runs?.submission?.coordinator { app.addServices(ReadWorkerService(coordinator:coordinator)) }
        if let beforeServing { app.beforeServerStarts(perform:beforeServing) }
        return app
    }

    private static func json(_ status: HTTPResponse.Status, _ body: String) -> Response {
        Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(string: body)))
    }
}
