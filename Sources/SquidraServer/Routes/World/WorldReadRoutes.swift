import Foundation
import Hummingbird
import SquidraDomain
import SquidraSecurity
import SquidraTools
import SquidraWorld

/// The authenticated local owner may read its actor's world. Permissions below
/// are minted by this host for an exact validated target, never from body scope.
struct WorldReadRoutes: Sendable {
    let actorID: UUID
    private let location: GatewayToolRegistration, changes: GatewayToolRegistration
    private let catalog: ToolCatalog
    init(actorID: UUID, world: any WorldStateQuery, changes: any WorldChangesQuerying) throws {
        self.actorID = actorID
        location = try WorldLocationTool(world:world).registration()
        self.changes = try WorldChangesTool(world:changes).registration()
        catalog = try ToolCatalog(definitions:[location.definition,self.changes.definition])
    }
    func mount(_ router: Router<BoundaryContext>) {
        router.post("/api/v1/world/location") { request,context in
            try await respond(request,context:context,registration:location)
        }
        router.post("/api/v1/world/changes") { request,context in
            try await respond(request,context:context,registration:changes)
        }
    }
    private func respond(_ request: Request, context: BoundaryContext, registration: GatewayToolRegistration) async throws -> Response {
        do {
            guard let actor = context.actorID else { throw HTTPError(.unauthorized) }
            try context.requireActor(actorID)
            guard request.headers[values:.contentType].count == 1,
                  request.headers[.contentType]?.split(separator:";",maxSplits:1).first?.trimmingCharacters(in:.whitespaces).lowercased() == "application/json" else { throw HTTPError(.badRequest) }
            let definition = registration.definition
            let body = try await request.body.collect(upTo:definition.maximumInputBytes)
            let arguments = try catalog.validateInput(Data(body.readableBytesView),for:definition.id)
            guard let object = try JSONSerialization.jsonObject(with:arguments) as? [String:Any] else { throw HTTPError(.badRequest) }
            // The generic schema dialect accepts broader RFC 3339 values than
            // Squidra's explicit storage profile. Reject them as wire input,
            // before the gateway's target-binding authorization check.
            do {
                func date(_ field: String) throws -> UTCInstant {
                    guard let text = object[field] as? String else { throw ToolError.invalidInput }
                    return try RFC3339.parse(text)
                }
                if definition.id.name == "get_entity_location" {
                    _ = try date("validAt"); _ = try date("knownAt")
                } else {
                    _ = try WorldChangesQuery(actorID:actor,from:date("from"),to:date("to"),knownAt:date("knownAt"))
                }
            } catch { throw HTTPError(.badRequest) }
            let target: String
            let field = definition.id.name == "get_entity_location" ? "entityId" : "subjectId"
            if let raw = object[field] as? String, let entity = UUID(uuidString:raw) { target = "entity:"+entity.uuidString.lowercased() }
            else if definition.id.name == "get_changes", object[field] == nil { target = "world:changes" }
            else { throw HTTPError(.badRequest) }
            let deadline = ContinuousClock.now.advanced(by:.seconds(5))
            let permission = HostActionPermission(actorID:actor,tool:definition.id,capability:definition.capability,
                targets:[target],scope:["world:read"],expiresAt:deadline)
            let gateway = try ActionGateway(tools:[registration],policy:HostActionPolicy(permissions:[permission]))
            let action = GatewayAction(actorID:actor,runID:context.requestID,tool:definition.id,target:target,arguments:arguments,
                scope:["world:read"],idempotencyKey:"http-read:"+context.requestID.uuidString.lowercased(),deadline:deadline)
            guard case .completed(let result) = try await gateway.invoke(action) else { throw HTTPError(.serviceUnavailable) }
            return Response(status:.ok,headers:[.contentType:"application/json"],body:.init(byteBuffer:.init(bytes:result.payload)))
        } catch { throw Self.mapped(error) }
    }
    private static func mapped(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? any HTTPResponseError { return error }
        if let error = error as? ToolError {
            switch error {
            case .invalidInput: return HTTPError(.badRequest)
            case .policyDenied: return HTTPError(.forbidden)
            case .timedOut: return HTTPError(.gatewayTimeout)
            default: return HTTPError(.serviceUnavailable)
            }
        }
        if let error = error as? ActionGatewayError {
            switch error {
            case .denied,.approvalRequired: return HTTPError(.forbidden)
            case .timedOut: return HTTPError(.gatewayTimeout)
            default: return HTTPError(.serviceUnavailable)
            }
        }
        return HTTPError(.serviceUnavailable)
    }
}
