import Crypto
import Foundation
import SquidraDomain
import XCTest
@testable import SquidraMeta
@testable import SquidraPerception

private actor NativeSAMTransport: MetaResponsesTransport {
    let text: String
    private(set) var calls = 0
    init(_ text: String) { self.text = text }
    func post(_ body: Data, maximumResponseBytes: Int, deadline: ContinuousClock.Instant) async throws -> MetaHTTPResponse {
        calls += 1
        let data = try JSONSerialization.data(withJSONObject:["object":"response","model":"sam-3.1","status":"completed",
            "output":[["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":text]]]]])
        return MetaHTTPResponse(status:200,contentType:"application/json",body:data)
    }
}
final class SAMNativeTests: XCTestCase, @unchecked Sendable {
    private struct Vector: Decodable { let width: Int,height: Int,payload: String;let rasterBase64: String?,name: String? }
    private struct Vectors: Decodable { let vectors: [Vector],invalid: [Vector] }
    private var root: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func vectors() throws -> Vectors { try JSONDecoder().decode(Vectors.self,from:Data(contentsOf:root.appendingPathComponent("fixtures/providers/sam-one-bit-vectors.v1.json"))) }
    private func payload() throws -> String { try XCTUnwrap(vectors().vectors.first { $0.name == "2x2-one" }).payload }
    private func line(id: String = "7", scores: String = "", maskScore: String = "", frame: Int = 4) throws -> String {
        try "<0f>\(id)<|box;x1=1;y1=1;x2=2;y2=2;w=\(frame);h=\(frame)\(scores)|><|mask;x=0;y=0\(maskScore);data=2,2,\(payload())|>"
    }
    private func parse(_ text: String, size: Int = 4) throws -> [SAMImageDetection] {
        try SAMImageSegmentation.decode(text,width:size,height:size,deadline:.now.advanced(by:.seconds(10)))
    }
    func testFortyReferenceVectorsDecodeExactly() throws {
        let fixtures = try vectors();XCTAssertEqual(fixtures.vectors.count,40)
        for v in fixtures.vectors {
            let expected = try XCTUnwrap(v.rasterBase64.flatMap { Data(base64Encoded: $0) })
            XCTAssertEqual(try SAMOneBitMask.decode(v.payload,width:v.width,height:v.height,deadline:.now.advanced(by:.seconds(10))),expected,v.name ?? "")
        }
    }
    func testReferenceRejectedTruncationAlphabetAndFinalization() throws {
        let fixtures = try vectors();XCTAssertGreaterThanOrEqual(fixtures.invalid.count,18)
        for v in fixtures.invalid {
            XCTAssertThrowsError(try SAMOneBitMask.decode(v.payload,width:v.width,height:v.height,deadline:.now.advanced(by:.seconds(10))))
        }
        for value in ["!","!é","!~~~~~","!"+String(repeating:"{",count:10)] {
            XCTAssertThrowsError(try SAMOneBitMask.decode(value,width:1,height:1,deadline:.now.advanced(by:.seconds(1))))
        }
        XCTAssertThrowsError(try SAMOneBitMask.decode("~payload",width:1,height:1,deadline:.now.advanced(by:.seconds(1)))) { XCTAssertEqual($0 as? SAMDecodeError,.unsupportedEncoding) }
    }
    func testQuotasDeadlineAndCancellationBeforeAllocation() async throws {
        let p = try payload()
        for (w,h) in [(0,1),(1,0),(1025,1),(Int.max,Int.max),(-1,1)] {
            XCTAssertThrowsError(try SAMOneBitMask.decode(p,width:w,height:h,deadline:.now.advanced(by:.seconds(1)))) { XCTAssertEqual($0 as? SAMDecodeError,.resourceLimit) }
        }
        XCTAssertThrowsError(try SAMOneBitMask.decode(String(repeating:"!",count:196609),width:1,height:1,deadline:.now.advanced(by:.seconds(1))))
        XCTAssertThrowsError(try SAMOneBitMask.decode(p,width:2,height:2,deadline:.now.advanced(by:.seconds(-1)))) { XCTAssertEqual($0 as? SAMDecodeError,.deadlineExceeded) }
        let task = Task { try? await Task.sleep(for:.milliseconds(10));return try SAMOneBitMask.decode(p,width:2,height:2,deadline:.now.advanced(by:.seconds(1))) }
        task.cancel()
        do { _ = try await task.value;XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testInclusiveCornersFullFrameEmbeddingAndIndependentOptionalConfidence() throws {
        let result = try XCTUnwrap(parse(line(scores:";c=.2",maskScore:";c=9e-1")).first)
        XCTAssertEqual(result.localID,"7");XCTAssertEqual(result.box,try PixelBox(x:1,y:1,width:2,height:2))
        XCTAssertEqual(result.mask.pixels,Data([0,0,0,0,0,1,1,0,0,1,1,0,0,0,0,0]))
        XCTAssertEqual(result.boxConfidence?.value,0.2);XCTAssertEqual(result.maskConfidence?.value,0.9)
        let absent = try XCTUnwrap(parse(line()).first);XCTAssertNil(absent.boxConfidence);XCTAssertNil(absent.maskConfidence)
        let partial = try XCTUnwrap(parse(line(scores:";c=1")).first);XCTAssertEqual(partial.boxConfidence?.value,1);XCTAssertNil(partial.maskConfidence)
        XCTAssertTrue(try parse("").isEmpty)
        let reversed = try "<0f>42<|mask;data=2,2,\(payload());y=0;x=0|><|box;h=4;w=4;y2=2;x2=2;y1=1;x1=1|>"
        XCTAssertEqual(try parse(reversed).first?.mask,result.mask)
    }
    func testInvalidFramesFieldsGeometryDuplicateIDsAndEmptyMasksReject() throws {
        let valid = try line()
        let zero = try XCTUnwrap(vectors().vectors.first { $0.name == "2x2-zero" }).payload
        let variants = ["<0f>",valid.replacingOccurrences(of:"<0f>",with:"<1f>"),valid+"\n"+valid,
            valid+","+valid.replacingOccurrences(of:"<0f>",with:""),valid+",",
            valid.replacingOccurrences(of:";w=4",with:";w=5"),valid.replacingOccurrences(of:";x2=2",with:";x2=4"),
            valid.replacingOccurrences(of:";y1=1",with:";y1=3"),valid.replacingOccurrences(of:";x=0",with:";x=1"),
            valid.replacingOccurrences(of:";w=4",with:";w=4;w=4"),valid.replacingOccurrences(of:";w=4",with:";w=4;extra=1"),
            valid.replacingOccurrences(of:"data=2,2,",with:"data=1,2,"),valid.replacingOccurrences(of:try payload(),with:zero),
            try line(scores:";c=NaN"),try line(scores:";c=1.1"),try line(scores:";c=.5;c=.6")]
        for value in variants { XCTAssertThrowsError(try parse(value)) }
        let records = try (0..<17).map { try line(id:String($0)).replacingOccurrences(of:"<0f>",with:"") }.joined(separator:",")
        XCTAssertThrowsError(try parse("<0f>"+records)) { XCTAssertEqual($0 as? SAMDecodeError,.resourceLimit) }
    }
    func testCapturedLiveMaskMatchesReferenceRasterHash() throws {
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("fixtures/providers/sam-image-live.v1.json"))) as? [String:Any])
        let report = try XCTUnwrap(wire["report"] as? [String:Any]),text = try XCTUnwrap(report["segmentationText"] as? String)
        let detection = try XCTUnwrap(parse(text,size:512).first)
        XCTAssertEqual(detection.box,try PixelBox(x:128,y:128,width:256,height:255))
        XCTAssertEqual(detection.mask.pixels.reduce(0) { $0+Int($1) },64849)
        var local = Data()
        for row in 128..<383 { local.append(detection.mask.pixels[row*512+128..<row*512+384]) }
        XCTAssertEqual(SHA256.hash(data:local).map { String(format:"%02x",$0) }.joined(),"15b728e509bba7561d4d76d9fee577b53ee6f9d82d2e9ecb581f6499c0679526")
    }
    func testVisionAdapterPreservesHostContextAndDoesNotActivateCloudIngestion() async throws {
        let bytes = try Data(contentsOf:root.appendingPathComponent("fixtures/providers/sam-red-square.png")),image = try PNGFrame(bytes:bytes,mediaType:"image/png")
        let context = try FrameContext(actorID:UUID(),cameraID:UUID(),frameID:UUID(),timestamps:ObservationTimestamps(occurredAt:nil,observedAt:UTCInstant(secondsSince1970:1),recordedAt:UTCInstant(secondsSince1970:2),timeZone:IANATimeZone(identifier:"UTC")))
        let digest = SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
        for missing in [false,true] {
            let transport = try NativeSAMTransport(line(scores:";c=.7",maskScore:missing ? "" : ";c=.9",frame:512))
            let model = try MetaSAMVisionModel(concept:"red square",transport:transport)
            let request = VisionRequest(context:context,image:image,imageSHA256:digest,deadline:.now.advanced(by:.seconds(5)))
            let result = try await model.detect(request)
            XCTAssertEqual(result.context,context);XCTAssertEqual(result.imageSHA256,digest);XCTAssertEqual(result.identity.deployment,.cloud)
            XCTAssertEqual(result.identity.version,"alias:sam-3.1");XCTAssertNil(result.detections.first?.appearance)
            XCTAssertEqual(result.detections.first?.confidence?.value,missing ? nil : 0.7)
            let consent = FrameImportConsent(actorID:context.actorID,cameraID:context.cameraID,permitsLocalProcessing:true,permitsCloudTransfer:true,expiresAt:.now.advanced(by:.seconds(5)))
            do { _ = try await FrameImporter(model:model).ingest(bytes:bytes,mediaType:"image/png",context:context,consent:consent,deadline:.now.advanced(by:.seconds(5)));XCTFail() }
            catch { XCTAssertEqual(error as? VisionError,.unavailable) }
            let calls = await transport.calls;XCTAssertEqual(calls,1)
        }
    }
}
