import Foundation
import SquidraCognition
import SquidraDomain
import SquidraMeta
import XCTest

private actor ProbeModel: LanguageModel {
    nonisolated let descriptor: ModelDescriptor
    enum Behavior: Sendable { case unavailable, echo, malformed, slow, opaqueFailure }
    let behavior: Behavior
    private(set) var calls = 0
    private(set) var inFlight = 0

    init(id: String, location: ModelLocation = .local, cost: Int64 = 0,
         priority: Int = 0, behavior: Behavior = .echo) {
        descriptor = ModelDescriptor(id: id, modelVersion: "test-1", location: location,
                                     capabilities: [.text], priority: priority, maximumCostMicroUSD: cost)
        self.behavior = behavior
    }

    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        calls += 1; inFlight += 1
        defer { inFlight -= 1 }
        switch behavior {
        case .unavailable: throw ModelProviderError.unavailable
        case .opaqueFailure: throw NSError(domain: "sentinel-secret", code: 1)
        case .slow: try await Task.sleep(for: .seconds(60))
        case .echo, .malformed: break
        }
        return ModelResponse(schemaVersion: behavior == .malformed ? "99" : "1",
            requestID: request.id, modelID: descriptor.id, modelVersion: descriptor.modelVersion,
            text: "fixture", outputTokens: 1, costMicroUSD: descriptor.maximumCostMicroUSD)
    }
}

final class ModelRouterTests: XCTestCase, @unchecked Sendable {
    // XCTest owns each instance; tests have no mutable instance state. No model
    // state crosses actors except immutable Sendable DTOs and awaited counters.
    // Follow-up: remove this XCTest-only conformance when the issue runner
    // gains Swift Testing support; production types use checked Sendable.
    private func clock() throws -> FixedClock {
        try FixedClock(instant: UTCInstant(secondsSince1970: 0), timeZone: IANATimeZone(identifier: "UTC"))
    }
    private func request(version: String = "1", preferred: String? = nil, cloud: Bool = false,
                         fallback: Bool = false, budget: Int64 = 0, deadline: Double = 100,
                         capabilities: Set<ModelCapability> = [.text]) throws -> ModelRequest {
        ModelRequest(schemaVersion: version, id: UUID(), messages: [ModelMessage(role: .user, content: "where?")],
            requiredCapabilities: capabilities, preferredModelID: preferred, cloudConsent: cloud,
            allowFallback: fallback, maximumCostMicroUSD: budget,
            deadline: try UTCInstant(secondsSince1970: deadline))
    }
    private func assertFailure(_ expected: ModelRoutingError, router: ModelRouter,
                               request: ModelRequest, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await router.generate(request); XCTFail("Expected typed failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? ModelRoutingError, expected, file: file, line: line) }
    }

    func testOfflineProviderIsDeterministic() async throws {
        let router = try ModelRouter(models: [DeterministicLanguageModel()], clock: clock())
        let input = try request()
        let first = try await router.generate(input)
        let second = try await router.generate(input)
        XCTAssertEqual(first.response.text, second.response.text)
        XCTAssertEqual(first.response.requestID, input.id)
        XCTAssertEqual(first.reservedCostUpperBoundMicroUSD, 0)
    }

    func testRoutingUsesStablePriorityAndIdentifier() async throws {
        let a = ProbeModel(id: "a"), b = ProbeModel(id: "b")
        let result = try await ModelRouter(models: [b, a], clock: clock()).generate(request())
        XCTAssertEqual(result.attemptedModelIDs, ["a"])
        let bCalls = await b.calls
        XCTAssertEqual(bCalls, 0)
    }

    func testCloudRequiresExplicitConsent() async throws {
        let cloud = ProbeModel(id: "cloud", location: .cloud)
        let router = try ModelRouter(models: [cloud], clock: clock())
        try await assertFailure(.privacyDenied, router: router, request: request())
        let calls = await cloud.calls
        XCTAssertEqual(calls, 0)
        let result = try await router.generate(request(cloud: true))
        XCTAssertEqual(result.response.modelID, "cloud")
    }

    func testFallbackRequiresConsent() async throws {
        let first = ProbeModel(id: "a", behavior: .unavailable), second = ProbeModel(id: "b")
        let router = try ModelRouter(models: [first, second], clock: clock())
        try await assertFailure(.fallbackNotPermitted, router: router, request: request())
        let calls = await second.calls
        XCTAssertEqual(calls, 0)
        let result = try await router.generate(request(fallback: true))
        XCTAssertEqual(result.attemptedModelIDs, ["a", "b"])
    }

    func testFallbackDoesNotImplyCloudConsent() async throws {
        let local = ProbeModel(id: "local", behavior: .unavailable)
        let cloud = ProbeModel(id: "cloud", location: .cloud, priority: 1)
        try await assertFailure(.providerUnavailable, router: ModelRouter(models: [local, cloud], clock: clock()),
                            request: request(fallback: true))
        let calls = await cloud.calls
        XCTAssertEqual(calls, 0)
    }

    func testFailedAttemptsConsumeConservativeCostBudget() async throws {
        let first = ProbeModel(id: "a", cost: 60, behavior: .unavailable)
        let second = ProbeModel(id: "b", cost: 60)
        try await assertFailure(.budgetExceeded, router: ModelRouter(models: [first, second], clock: clock()),
                            request: request(fallback: true, budget: 100))
        let calls = await second.calls
        XCTAssertEqual(calls, 0)
    }

    func testMalformedResponseIsRejectedWithoutFallback() async throws {
        let first = ProbeModel(id: "a", behavior: .malformed), second = ProbeModel(id: "b")
        try await assertFailure(.invalidResponse, router: ModelRouter(models: [first, second], clock: clock()),
                            request: request(fallback: true))
        let calls = await second.calls
        XCTAssertEqual(calls, 0)
    }

    func testRequestValidationRunsBeforeInvocation() async throws {
        let model = ProbeModel(id: "a")
        let router = try ModelRouter(models: [model], clock: clock())
        try await assertFailure(.unsupportedSchemaVersion, router: router, request: request(version: "99"))
        try await assertFailure(.unsupportedCapabilities, router: router, request: request(capabilities: [.vision]))
        try await assertFailure(.deadlineExceeded, router: router, request: request(deadline: 0))
        try await assertFailure(.invalidRequest, router: router, request: request(deadline: 181))
        let calls = await model.calls
        XCTAssertEqual(calls, 0)
    }

    func testPreferredModelMustBeEligible() async throws {
        let model = ProbeModel(id: "cloud", location: .cloud, cost: 10)
        let router = try ModelRouter(models: [model, DeterministicLanguageModel()], clock: clock())
        try await assertFailure(.providerUnavailable, router: router, request: request(preferred: "missing"))
        try await assertFailure(.privacyDenied, router: router, request: request(preferred: "cloud"))
        try await assertFailure(.budgetExceeded, router: router, request: request(preferred: "cloud", cloud: true))
    }

    func testOpaqueProviderErrorsDoNotLeakDetails() async throws {
        let model = ProbeModel(id: "a", behavior: .opaqueFailure)
        try await assertFailure(.providerFailure, router: ModelRouter(models: [model], clock: clock()), request: request())
    }

    func testDeadlineCancelsCooperativeAdapter() async throws {
        let model = ProbeModel(id: "slow", behavior: .slow)
        try await assertFailure(.deadlineExceeded, router: ModelRouter(models: [model], clock: clock()),
                            request: request(deadline: 0.01))
        let inFlight = await model.inFlight
        XCTAssertEqual(inFlight, 0)
    }

    func testParentCancellationPropagates() async throws {
        let model = ProbeModel(id: "slow", behavior: .slow)
        let router = try ModelRouter(models: [model], clock: clock()), input = try request()
        let task = Task { @concurrent in try await router.generate(input) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let inFlight = await model.inFlight
        XCTAssertEqual(inFlight, 0)
    }

    func testNoConfiguredProviderIsExplicitlyUnavailable() async throws {
        try await assertFailure(.providerUnavailable, router: ModelRouter(models: [], clock: clock()), request: request())
    }

    func testDuplicateProvidersAreRejected() throws {
        XCTAssertThrowsError(try ModelRouter(models: [DeterministicLanguageModel(), DeterministicLanguageModel()], clock: clock()))
    }
}
