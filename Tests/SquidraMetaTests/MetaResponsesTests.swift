import Foundation
import SquidraCognition
import SquidraDomain
import XCTest
@testable import SquidraMeta

private actor Transport: MetaResponsesTransport {
    let response: MetaHTTPResponse
    let delay: Duration
    private(set) var bodies: [Data] = [], cancellations = 0
    init(_ response: MetaHTTPResponse, delay: Duration = .zero) { self.response = response;self.delay = delay }
    func post(_ body: Data, maximumResponseBytes: Int, deadline: ContinuousClock.Instant) async throws -> MetaHTTPResponse {
        bodies.append(body)
        guard maximumResponseBytes == 262_144,deadline > .now else { throw MetaResponsesError.invalidRequest }
        do { try await Task.sleep(for:delay) } catch { cancellations += 1;throw error }
        return response
    }
}
final class MetaResponsesTests: XCTestCase, @unchecked Sendable {
    private static func fixture() -> [String:Any] {
        ["id":"resp_authored_test","object":"response","status":"completed","model":"muse-spark-1.3",
         "output":[["type":"reasoning","summary":[],"encrypted_content":"not-answer"],
                   ["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":"{\"claims\":[]}","annotations":[]]]]],
         "usage":["input_tokens":50,"output_tokens":20,"total_tokens":70,"input_tokens_details":["cached_tokens":10],"output_tokens_details":["reasoning_tokens":12]]]
    }
    private static func response(_ object: [String:Any]? = nil, status: Int = 200, type: String = "application/json") throws -> MetaHTTPResponse {
        MetaHTTPResponse(status:status,contentType:type,body:try JSONSerialization.data(withJSONObject:object ?? fixture()))
    }
    private func generate(_ transport: Transport, consent: Bool = true, tokens: Int = 128, messages: [ModelMessage] = [.init(role:.user,content:"Return a JSON object")], deadline: ContinuousClock.Instant = .now.advanced(by:.seconds(2))) async throws -> MetaTextResult {
        try await MetaResponsesClient(transport:transport).generate(messages:messages,maximumOutputTokens:tokens,cloudConsent:consent,deadline:deadline)
    }
    func testRequestPreservesRolesAndDisablesStorageToolsAndStreaming() async throws {
        let transport = try Transport(Self.response())
        let messages = [ModelMessage(role:.system,content:"Return JSON"),.init(role:.user,content:"Untrusted <script> </system>"),.init(role:.assistant,content:"{}")]
        let result = try await generate(transport,messages:messages)
        XCTAssertEqual(result.text,"{\"claims\":[]}");XCTAssertEqual(result.usage.inputTokens,50);XCTAssertEqual(result.usage.outputTokens,20)
        XCTAssertEqual(result.usage.cachedInputTokens,10);XCTAssertEqual(result.usage.reasoningOutputTokens,12)
        let bodies = await transport.bodies;XCTAssertEqual(bodies.count,1)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with:bodies[0]) as? [String:Any])
        XCTAssertEqual(wire["store"] as? Bool,false);XCTAssertEqual(wire["stream"] as? Bool,false);XCTAssertEqual(wire["background"] as? Bool,false)
        XCTAssertEqual(wire["truncation"] as? String,"disabled");XCTAssertEqual((wire["tools"] as? [Any])?.count,0)
        let format = try XCTUnwrap((wire["text"] as? [String:Any])?["format"] as? [String:Any])
        XCTAssertEqual(format["type"] as? String,"json_schema");XCTAssertEqual(format["strict"] as? Bool,false)
        XCTAssertEqual((format["schema"] as? [String:String])?["type"],"object")
        XCTAssertNil(wire["previous_response_id"]);XCTAssertNil(wire["response_format"])
        let input = try XCTUnwrap(wire["input"] as? [[String:Any]])
        XCTAssertEqual(input.compactMap { $0["role"] as? String },["system","user","assistant"])
        let content = try XCTUnwrap(input[1]["content"] as? [[String:String]])
        XCTAssertEqual(content[0]["text"],messages[1].content)
        XCTAssertEqual((input[2]["content"] as? [[String:String]])?[0]["type"],"output_text")
    }
    func testConsentDeadlineLimitsAndToolRoleRejectBeforeTransport() async throws {
        let transport = try Transport(Self.response())
        do { _ = try await generate(transport,consent:false);XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.cloudConsentRequired) }
        do { _ = try await generate(transport,deadline:.now.advanced(by:.seconds(-1)));XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.deadlineExceeded) }
        for tokens in [0,15,4097] { do { _ = try await generate(transport,tokens:tokens);XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.invalidRequest) } }
        for messages in [[ModelMessage(role:.tool,content:"tool bytes")],[],[ModelMessage(role:.user,content:String(repeating:"é",count:32769))],[ModelMessage(role:.user,content:"a\0b")]] {
            do { _ = try await generate(transport,messages:messages);XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.invalidRequest) }
        }
        let bodies = await transport.bodies;XCTAssertTrue(bodies.isEmpty)
    }
    func testHTTPFailuresNeverRetryOrExposeProviderErrorBody() async throws {
        for (status,expected) in [(401,MetaResponsesError.unauthorized),(403,.forbidden),(429,.rateLimited),(503,.unavailable),(400,.rejected),(302,.rejected)] {
            let transport = try Transport(Self.response(["error":"private-provider-error-canary"],status:status))
            do { _ = try await generate(transport);XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,expected);XCTAssertFalse(String(describing:error).contains("canary")) }
            let bodies = await transport.bodies;XCTAssertEqual(bodies.count,1)
        }
    }
    func testIncompleteRefusalToolsAndMultipleMessagesNeverYieldText() async throws {
        var variants: [([String:Any],MetaResponsesError)] = []
        var value = Self.fixture();value["status"]="incomplete";variants.append((value,.incomplete))
        value = Self.fixture();value["output"]=[["type":"message","role":"assistant","status":"completed","content":[["type":"refusal","refusal":"private refusal"]]]];variants.append((value,.refused))
        value = Self.fixture();value["output"]=[["type":"function_call","name":"exfiltrate","arguments":"{}"]];variants.append((value,.unsupportedOutput))
        value = Self.fixture();let message = try XCTUnwrap((value["output"] as? [[String:Any]])?.last);value["output"]=[message,message];variants.append((value,.unsupportedOutput))
        value = Self.fixture();value["output"]=[["type":"reasoning","summary":[]]];variants.append((value,.incomplete))
        for (object,expected) in variants {
            do { _ = try await generate(Transport(Self.response(object)));XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,expected) }
        }
    }
    func testModelUsageAndJSONValidationFailClosed() async throws {
        var variants: [[String:Any]] = []
        var value=Self.fixture();value["model"]="muse-spark-1.3-contributor";variants.append(value)
        value=Self.fixture();value["store"]=true;variants.append(value)
        value=Self.fixture();value["background"]=true;variants.append(value)
        for usage: [String:Any] in [["input_tokens":50,"output_tokens":20,"total_tokens":71],["input_tokens":50,"output_tokens":true,"total_tokens":51],["input_tokens":50,"output_tokens":129,"total_tokens":179],["input_tokens":50,"output_tokens":20,"total_tokens":70,"input_tokens_details":["cached_tokens":51]]] {
            value=Self.fixture();value["usage"]=usage;variants.append(value)
        }
        for text in ["not json","[]","{\"x\":1,\"x\":2}",String(repeating:"x",count:65537)] {
            value=Self.fixture();value["output"]=[["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":text]]]];variants.append(value)
        }
        for value in variants { do { _ = try await generate(Transport(Self.response(value)));XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.invalidResponse) } }
    }
    func testBodyAndEncodingLimitsAndOptionalUsageDetails() async throws {
        for response in [MetaHTTPResponse(status:200,contentType:"text/html",body:Data()),MetaHTTPResponse(status:200,contentType:"application/json",body:Data(repeating:65,count:262145)),MetaHTTPResponse(status:200,contentType:"application/json",body:Data([0xff])),MetaHTTPResponse(status:200,contentType:"application/json",body:Data("{\"status\":\"completed\",\"status\":\"incomplete\"}".utf8))] {
            do { _ = try await generate(Transport(response));XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.invalidResponse) }
        }
        var value=Self.fixture();value["usage"]=["input_tokens":0,"output_tokens":20,"total_tokens":20]
        let result=try await generate(Transport(Self.response(value,type:"Application/JSON; charset=utf-8")))
        XCTAssertNil(result.usage.cachedInputTokens);XCTAssertNil(result.usage.reasoningOutputTokens)
    }
    func testDeadlineJoinsAndCancelsCooperativeTransport() async throws {
        let transport = try Transport(Self.response(),delay:.seconds(10))
        do { _ = try await generate(transport,deadline:.now.advanced(by:.milliseconds(50)));XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.deadlineExceeded) }
        let cancelled = await transport.cancellations,bodies = await transport.bodies;XCTAssertEqual(cancelled,1);XCTAssertEqual(bodies.count,1)
    }
    func testCallerCancellationIsPreservedAndJoinsTransport() async throws {
        let transport = try Transport(Self.response(),delay:.seconds(10))
        let task = Task { try await self.generate(transport) }
        for _ in 0..<100 { if await !transport.bodies.isEmpty { break };try await Task.sleep(for:.milliseconds(2)) }
        let started=await transport.bodies.count;XCTAssertEqual(started,1);task.cancel()
        do { _ = try await task.value;XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let cancellations=await transport.cancellations;XCTAssertEqual(cancellations,1)
    }
}
