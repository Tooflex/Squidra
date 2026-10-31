import Foundation
import Hummingbird
import Logging
import SquidraProtocols
import SquidraPostgres
import SquidraDomain
import SquidraSecurity
import SquidraTemporal
import SquidraTools
import PostgresNIO

/// Composition owns dependencies per application. No global runtime or store.
enum ServerComposition {
    static func live(configuration: ServerConfiguration) throws -> some ApplicationProtocol {
        let client = configuration.database.makeClient()
        let readiness = PostgresSchemaReadiness(client: client)
        let approvals = ApprovalCoordinator(store:PostgresApprovalStore(client:client),clock:SystemClock(timeZone:try! IANATimeZone(identifier:"Etc/UTC")))
        let world = PostgresLocationProjection(actorID:configuration.boundary.actorID,client:client)
        let worldReads = try WorldReadRoutes(actorID:configuration.boundary.actorID,world:world,changes:world)
        let recovery = WorldProjectionRecovery(actorID:configuration.boundary.actorID,
            repository:PostgresWorldRepository(client:client),projector:world)
        return application(configuration: configuration, readiness: { try await readiness.check() }, client: client,
            approvals:approvals,ledger:PostgresActionLedger(client:client),worldReads:worldReads,
            runs:try! RunRoutes.Dependencies(actorID:configuration.boundary.actorID,
                events:PostgresRunEventStore(client:client,actorID:configuration.boundary.actorID),
                publication:PostgresRunPublicationStore(client:client,actorID:configuration.boundary.actorID),runtime:PostgresRunStore(client:client)),
            beforeServing:{ _ = try await recovery.recover() })
    }

    static func application(configuration: ServerConfiguration,
                            readiness: @escaping @Sendable () async throws -> DatabaseReadiness,
                            client: PostgresClient? = nil, approvals: ApprovalCoordinator? = nil, ledger: (any ActionLedgerStore)? = nil,
                            worldReads: WorldReadRoutes? = nil, runs: RunRoutes.Dependencies? = nil,
                            beforeServing: (@Sendable () async throws -> Void)? = nil) -> some ApplicationProtocol {
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
        if let coordinator = runs?.submission?.coordinator { app.addServices(ReadWorkerService(coordinator:coordinator)) }
        if let beforeServing { app.beforeServerStarts(perform:beforeServing) }
        return app
    }

    private static func json(_ status: HTTPResponse.Status, _ body: String) -> Response {
        Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(string: body)))
    }
}
