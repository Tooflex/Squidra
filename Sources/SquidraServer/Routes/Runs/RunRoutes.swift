import Foundation
import Hummingbird
import SquidraAgentRuntime
import SquidraCognition
import SquidraDomain
import SquidraProtocols

/// Squidra's authenticated POST-202 / finite GET-SSE extension, not the
/// official HttpAgent POST-SSE transport. GET has no execution path.
enum RunRoutes {
    struct Submission: Sendable {
        let coordinator: PublishedReadRunCoordinator, clock: any SquidraDomain.Clock
        let entities: [PlanningEntity], budget: RunBudget
        let preferredModelID: String?, cloudConsent: Bool, allowFallback: Bool
        let maximumCostMicroUSD: Int64, maximumOutputTokens: Int
        init(coordinator: PublishedReadRunCoordinator, clock: any SquidraDomain.Clock, entities: [PlanningEntity],
             budget: RunBudget = try! RunBudget(), preferredModelID: String? = nil, cloudConsent: Bool = false, allowFallback: Bool = false,
             maximumCostMicroUSD: Int64 = 0, maximumOutputTokens: Int = 512) throws {
            guard !entities.isEmpty,entities.count <= 32,Set(entities.map(\.id)).count == entities.count,
                  maximumCostMicroUSD >= 0,(1...4096).contains(maximumOutputTokens) else { throw ReadRunSubmissionError.invalidRequest }
            self.coordinator = coordinator;self.clock = clock;self.entities = entities;self.budget = budget
            self.preferredModelID = preferredModelID;self.cloudConsent = cloudConsent;self.allowFallback = allowFallback
            self.maximumCostMicroUSD = maximumCostMicroUSD;self.maximumOutputTokens = maximumOutputTokens
        }
    }
    struct Dependencies: Sendable {
        let actorID: UUID, events: any RunEventStore, publication: any RunPublicationStore, runtime: (any RunStore)?
        let submission: Submission?, maximumWait: Duration
        init(actorID: UUID, events: any RunEventStore, publication: any RunPublicationStore, runtime: (any RunStore)? = nil,
             submission: Submission? = nil, maximumWait: Duration = .seconds(20)) throws {
            guard maximumWait >= .zero,maximumWait <= .seconds(20) else { throw ReadRunSubmissionError.invalidRequest }
            self.actorID = actorID;self.events = events;self.publication = publication;self.runtime = runtime
            self.submission = submission;self.maximumWait = maximumWait
        }
    }
    private struct Capabilities: Encodable {
        let schemaVersion = "1"
        let textRuns: Bool
        let limitation: String?
    }
    static let lastEventID = "Last-Event-ID"
    static func mount(_ router: Router<BoundaryContext>, dependencies: Dependencies?) {
        router.get("/api/v1/run-capabilities") { request,context in
            guard let dependencies else { throw HTTPError(.serviceUnavailable) }
            try context.requireActor(dependencies.actorID)
            guard request.uri.query == nil else { throw HTTPError(.badRequest) }
            for try await part in request.body { guard part.readableBytes == 0 else { throw HTTPError(.badRequest) } }
            let enabled = dependencies.submission != nil
            return try json(.ok,Capabilities(textRuns:enabled,limitation:enabled ? nil : "no_configured_read_host"))
        }
        router.post("/api/v1/runs") { request,context in
            do {
                guard let dependencies,let submission = dependencies.submission else { throw HTTPError(.serviceUnavailable) }
                try context.requireActor(dependencies.actorID)
                guard request.uri.query == nil,request.headers[values:.contentType].count == 1,
                      request.headers[.contentType]?.split(separator:";",maxSplits:1).first?.trimmingCharacters(in:.whitespaces).lowercased() == "application/json" else { throw HTTPError(.badRequest) }
                let input = try await parse(request)
                guard let entity = submission.entities.first(where:{ $0.id == input.entityId }) else { throw HTTPError(.forbidden) }
                guard let intent = AnswerIntent(rawValue:input.intent) else { throw HTTPError(.badRequest) }
                let now = try submission.clock.now(),trace = UUID()
                let request = try ReadRunRequest(actorID:dependencies.actorID,traceID:trace,requestID:context.requestID,question:input.question,
                    planningScope:ReadPlanningScope(entities:[entity]),effectiveToolScope:["world:read"],intent:intent,
                    modelOptions:ReadPlanningOptions(preferredModelID:submission.preferredModelID,cloudConsent:submission.cloudConsent,allowFallback:submission.allowFallback,
                        maximumCostMicroUSD:submission.maximumCostMicroUSD,maximumOutputTokens:submission.maximumOutputTokens,
                        deadline:UTCInstant(secondsSince1970:now.secondsSince1970+Double(submission.budget.activeMilliseconds)/1000)),budget:submission.budget)
                let binding = try await submission.coordinator.submit(request,threadID:UUID())
                var response = try json(.accepted,RunHTTPAcceptance(binding:binding,traceID:trace))
                response.headers[.location] = "/api/v1/runs/"+binding.runID.uuidString.lowercased()
                return response
            } catch { throw mapped(error) }
        }
        router.post("/api/v1/runs/:run/cancel") { request,context in
            do {
                guard let dependencies else { throw HTTPError(.serviceUnavailable) }
                let id = try await identity(request,context:context,dependencies:dependencies,mutation:true)
                let before = try await dependencies.publication.status(actorID:dependencies.actorID,runID:id,deadline:.now.advanced(by:.seconds(4)))
                if before.stream.isTerminal { return try json(.ok,RunHTTPStatus(before,runtime:nil)) }
                guard let submission = dependencies.submission else { throw HTTPError(.serviceUnavailable) }
                let accepted = try await submission.coordinator.requestCancellation(actorID:dependencies.actorID,runID:id)
                // Reload even if ownership was released during the lookup. An
                // orphaned active run needs recovery, not a fabricated cancellation.
                let after = try await dependencies.publication.status(actorID:dependencies.actorID,runID:id,deadline:.now.advanced(by:.seconds(4)))
                guard accepted || after.stream.isTerminal else { throw HTTPError(.conflict) }
                return try json(accepted ? .accepted : .ok,RunHTTPStatus(after,runtime:nil))
            } catch { throw mapped(error) }
        }
        router.get("/api/v1/runs/:run") { request,context in
            do {
                guard let dependencies else { throw HTTPError(.serviceUnavailable) }
                let id = try await identity(request,context:context,dependencies:dependencies)
                let status = try await dependencies.publication.status(actorID:dependencies.actorID,runID:id,deadline:.now.advanced(by:.seconds(4)))
                var runtime:RunHTTPRuntimeStatus?
                if let store = dependencies.runtime {
                    do {
                        let snapshot = try await store.load(actorID:dependencies.actorID,runID:id,deadline:.now.advanced(by:.seconds(4)))
                        guard snapshot.actorID == dependencies.actorID,snapshot.id == id else { throw HTTPError(.serviceUnavailable) }
                        runtime = RunHTTPRuntimeStatus(state:snapshot.state.rawValue,traceID:snapshot.traceID,version:snapshot.version,
                            activeMilliseconds:snapshot.activeMilliseconds,steps:snapshot.steps,calls:snapshot.calls)
                    } catch RunStoreError.notFound { runtime = nil }
                }
                return try json(.ok,RunHTTPStatus(status,runtime:runtime))
            } catch { throw mapped(error) }
        }
        router.get("/api/v1/runs/:run/events") { request,context in
            let hardEnd = ContinuousClock.now.advanced(by:.seconds(25))
            do {
                guard let dependencies else { throw HTTPError(.serviceUnavailable) }
                let id = try await identity(request,context:context,dependencies:dependencies)
                // Owned lookup precedes decoding/validating any resume position.
                _ = try await dependencies.publication.status(actorID:dependencies.actorID,runID:id,deadline:min(hardEnd,.now.advanced(by:.seconds(4))))
                guard request.headers[values:.init(lastEventID)!].count <= 1 else { throw HTTPError(.badRequest) }
                let cursor = request.headers[.init(lastEventID)!]
                let waitEnd = ContinuousClock.now.advanced(by:dependencies.maximumWait)
                while true {
                    let page = try await dependencies.events.page(actorID:dependencies.actorID,runID:id,cursor:cursor,limit:32,
                        deadline:min(hardEnd,.now.advanced(by:.seconds(4))))
                    if !page.records.isEmpty || page.info.isTerminal || ContinuousClock.now >= waitEnd {
                        var body = Data()
                        for record in page.records {
                            let frame = try record.encodedSSE()
                            guard frame.count <= 1_100_000-body.count else { throw HTTPError(.serviceUnavailable) }
                            body.append(frame)
                        }
                        if body.isEmpty { body = AGUIStreamRecord.heartbeat }
                        return Response(status:.ok,headers:[.contentType:"text/event-stream; charset=utf-8",.cacheControl:"no-store"],body:.init(byteBuffer:.init(bytes:body)))
                    }
                    try await ContinuousClock().sleep(until:min(waitEnd,.now.advanced(by:.milliseconds(250))))
                }
            } catch { throw mapped(error) }
        }
    }
    private static func identity(_ request:Request,context:BoundaryContext,dependencies:Dependencies,mutation:Bool = false) async throws -> UUID {
        try context.requireActor(dependencies.actorID)
        guard request.method == (mutation ? .post : .get),request.uri.query == nil,let id = UUID(uuidString:context.parameters.get("run") ?? "") else { throw HTTPError(.badRequest) }
        for try await part in request.body { guard part.readableBytes == 0 else { throw HTTPError(.badRequest) } }
        return id
    }
    private static func parse(_ request:Request) async throws -> RunHTTPSubmission {
        var bytes = ByteBuffer()
        for try await part in request.body {
            guard part.readableBytes <= 32_768-bytes.readableBytes else { throw HTTPError(.contentTooLarge) }
            bytes.writeImmutableBuffer(part)
        }
        do {
            let document = try JSONDocument(Data(bytes.readableBytesView),maximumBytes:32_768)
            guard document.kind == .object,!document.containsNUL,let object = try JSONSerialization.jsonObject(with:document.bytes) as? [String:Any],
                  Set(object.keys) == ["schemaVersion","question","entityId","intent"] else { throw HTTPError(.badRequest) }
            let input = try JSONDecoder().decode(RunHTTPSubmission.self,from:document.bytes)
            guard input.schemaVersion == "1",input.question.utf8.count <= 4096,!input.question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  AnswerIntent(rawValue:input.intent) != nil else { throw HTTPError(.badRequest) }
            return input
        } catch { throw HTTPError(.badRequest) }
    }
    private static func json<Value:Encodable>(_ status:HTTPResponse.Status,_ value:Value) throws -> Response {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        return try Response(status:status,headers:[.contentType:"application/json"],body:.init(byteBuffer:.init(bytes:encoder.encode(value))))
    }
    private static func mapped(_ error:Error) -> Error {
        if error is CancellationError { return error }
        if let error = error as? any HTTPResponseError { return error }
        switch error {
        case RunEventStoreError.notFound: return HTTPError(.notFound)
        case RunEventStoreError.expired: return HTTPError(.gone)
        case RunEventStoreError.invalidRequest: return HTTPError(.badRequest)
        case RunEventStoreError.conflict,ReadRunSubmissionError.conflict: return HTTPError(.conflict)
        case RunEventStoreError.limitExceeded: return HTTPError(.contentTooLarge)
        case RunEventStoreError.timedOut: return HTTPError(.gatewayTimeout)
        case RunEventStoreError.cancelled,ReadRunSubmissionError.cancelled: return CancellationError()
        case ReadRunSubmissionError.invalidRequest: return HTTPError(.badRequest)
        default: return HTTPError(.serviceUnavailable)
        }
    }
}
