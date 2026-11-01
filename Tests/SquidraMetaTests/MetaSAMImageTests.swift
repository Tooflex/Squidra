import Foundation
import SquidraPerception
import XCTest
@testable import SquidraMeta

private actor SAMTransport: MetaResponsesTransport {
    let response: MetaHTTPResponse
    let delay: Duration
    private(set) var bodies: [Data] = [], cancelled = false
    init(_ value: Data, status: Int = 200, delay: Duration = .zero) throws {
        response = MetaHTTPResponse(status:status,contentType:"application/json",body:value);self.delay = delay
    }
    func post(_ body: Data, maximumResponseBytes: Int, deadline: ContinuousClock.Instant) async throws -> MetaHTTPResponse {
        bodies.append(body)
        do { try await Task.sleep(for:delay) } catch { cancelled = true;throw error }
        return response
    }
}
private func makeTransport(_ value: [String:Any], status: Int = 200, delay: Duration = .zero) throws -> SAMTransport {
    try SAMTransport(JSONSerialization.data(withJSONObject:value),status:status,delay:delay)
}
final class MetaSAMImageTests: XCTestCase, @unchecked Sendable {
    private func image() throws -> PNGFrame {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try PNGFrame(bytes:Data(contentsOf:root.appendingPathComponent("fixtures/providers/sam-red-square.png")),mediaType:"image/png")
    }
    private func wire(_ text: String = "") -> [String:Any] {
        ["object":"response","model":"sam-3.1","status":"completed","output":[["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":text]]]]]
    }
    private func run(_ transport: SAMTransport, consent: Bool = true, concept: String = "red square", deadline: ContinuousClock.Instant = .now.advanced(by:.seconds(2))) async throws -> MetaSAMImageResult {
        try await MetaSAMImageClient(transport:transport).segment(image:image(),concept:concept,permitsCloudImageTransfer:consent,deadline:deadline)
    }
    func testExplicitCloudConsentAndRequestGuardsBeforeTransport() async throws {
        let transport = try makeTransport(wire())
        do { _ = try await run(transport,consent:false);XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.cloudConsentRequired) }
        for concept in [""," ","red\nsquare","<0f>",String(repeating:"x",count:129)] {
            do { _ = try await run(transport,concept:concept);XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.invalidRequest) }
        }
        do { _ = try await run(transport,deadline:.now.advanced(by:.seconds(-1)));XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.deadlineExceeded) }
        func checksum(_ data: Data) -> Data {
            var crc: UInt32 = 0xffffffff
            for byte in data { crc ^= UInt32(byte);for _ in 0..<8 { crc = crc & 1 == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1 } }
            crc ^= 0xffffffff
            return Data([UInt8((crc >> 24)&255),UInt8((crc >> 16)&255),UInt8((crc >> 8)&255),UInt8(crc&255)])
        }
        var wide = try image().bytes
        wide.replaceSubrange(16..<20,with:[0,0,4,1]) // 1025, valid envelope but over this client's cap.
        wide.replaceSubrange(29..<33,with:checksum(wide.subdata(in:12..<29)))
        var large = try image().bytes
        let payload = Data("tEXt".utf8)+Data(repeating:65,count:65_536)
        large.insert(contentsOf:Data([0,1,0,0])+payload+checksum(payload),at:33)
        for data in [wide,large] {
            let frame = try PNGFrame(bytes:data,mediaType:"image/png")
            do { _ = try await MetaSAMImageClient(transport:transport).segment(image:frame,concept:"red square",permitsCloudImageTransfer:true,deadline:.now.advanced(by:.seconds(2)));XCTFail() }
            catch { XCTAssertEqual(error as? MetaResponsesError,.invalidRequest) }
        }
        let bodies = await transport.bodies;XCTAssertTrue(bodies.isEmpty)
    }
    func testImageRequestUsesInlinePNGAndStringMetadata() async throws {
        let transport = try makeTransport(wire("<0f>raw-unvalidated-geometry"))
        let result = try await run(transport)
        XCTAssertEqual(result.segmentationText,"<0f>raw-unvalidated-geometry");XCTAssertNil(result.imagesProcessed)
        let bodies = await transport.bodies;XCTAssertEqual(bodies.count,1)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with:bodies[0]) as? [String:Any])
        XCTAssertEqual(value["model"] as? String,"sam-3.1");XCTAssertEqual(value["stream"] as? Bool,false)
        XCTAssertEqual(value["store"] as? Bool,false);XCTAssertEqual(value["background"] as? Bool,false)
        XCTAssertEqual(value["metadata"] as? [String:String],["mask_encoding":"one_bit","include_confidence":"true"])
        XCTAssertNil(value["text"]);XCTAssertNil(value["tools"]);XCTAssertNil(value["previous_response_id"])
        let content = try XCTUnwrap((value["input"] as? [[String:Any]])?.first?["content"] as? [[String:String]])
        XCTAssertEqual(content.count,2);XCTAssertEqual(content[1]["image_url"],"data:image/png;base64,"+(try image().bytes.base64EncodedString()))
    }
    func testCompletedEmptyLaneIsNotMissingLaneOrInventedUsage() async throws {
        let empty = try await run(makeTransport(wire()));XCTAssertTrue(empty.segmentationText.isEmpty);XCTAssertNil(empty.imagesProcessed)
        var value=wire();value["usage"]=["images_processed":1]
        let measured = try await run(makeTransport(value));XCTAssertEqual(measured.imagesProcessed,1)
        for count: Any in [0,2,true,-1] {
            value["usage"]=["images_processed":count]
            do { _ = try await run(makeTransport(value));XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.invalidResponse) }
        }
        value=wire();value["output"]=[]
        do { _ = try await run(makeTransport(value));XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.unsupportedOutput) }
    }
    func testPartialWrongModelRefusalAndHTTPFailureReject() async throws {
        var variants: [([String:Any],MetaResponsesError)] = []
        var value=wire();value["status"]="incomplete";variants.append((value,.incomplete))
        value=wire();value["model"]="muse-spark-1.3";variants.append((value,.invalidResponse))
        value=wire();value["store"]=true;variants.append((value,.invalidResponse))
        value=wire();value["output"]=[["type":"message","role":"assistant","status":"completed","content":[["type":"refusal"]]]];variants.append((value,.refused))
        for (value,error) in variants { do { _ = try await run(makeTransport(value));XCTFail() } catch let actual { XCTAssertEqual(actual as? MetaResponsesError,error) } }
        let transport = try makeTransport(["error":"private-canary"],status:403)
        do { _ = try await run(transport);XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.forbidden) }
        let bodies=await transport.bodies;XCTAssertEqual(bodies.count,1)
    }
    func testDeadlineCancelsAndJoinsTransport() async throws {
        let transport = try makeTransport(wire(),delay:.seconds(10))
        do { _ = try await run(transport,deadline:.now.advanced(by:.milliseconds(50)));XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.deadlineExceeded) }
        let cancelled=await transport.cancelled;XCTAssertTrue(cancelled)
    }
}
