import Crypto
import Foundation
import SquidraDomain
import SquidraMeta
import SquidraPerception
import XCTest

private actor VisionProbe: VisionModel {
    enum Mode: Sendable { case empty, wrongActor, wrongCamera, wrongFrame, wrongTime, wrongModel, wrongDigest, excessive, duplicate, outside, emptyMask, mismatchedMask, absentConfidence, slow, privateError }
    nonisolated let identity: VisionIdentity
    let mode: Mode
    private(set) var calls = 0
    private(set) var cancelled = false
    init(_ mode: Mode = .empty, deployment: VisionDeployment = .local) throws {
        self.mode = mode; identity = try VisionIdentity(modelID: "fixture.probe", version: "1", deployment: deployment)
    }
    func detect(_ request: VisionRequest) async throws -> VisionOutput {
        calls += 1
        if mode == .privateError { throw NSError(domain: "secret-provider-response", code: 7) }
        if mode == .slow {
            do { try await ContinuousClock().sleep(for: .seconds(30)) }
            catch { cancelled = true; throw error }
        }
        var context = request.context
        if mode == .wrongActor || mode == .wrongCamera || mode == .wrongFrame || mode == .wrongTime {
            context = try FrameContext(actorID: mode == .wrongActor ? UUID() : context.actorID, cameraID: mode == .wrongCamera ? UUID() : context.cameraID,
                frameID: mode == .wrongFrame ? UUID() : context.frameID,
                timestamps: mode == .wrongTime ? ObservationTimestamps(occurredAt: nil,
                    observedAt: UTCInstant(secondsSince1970: 1), recordedAt: UTCInstant(secondsSince1970: 2),
                    timeZone: IANATimeZone(identifier: "UTC")) : context.timestamps)
        }
        var detections: [VisionDetection] = []
        if [.excessive,.duplicate,.outside,.emptyMask,.mismatchedMask,.absentConfidence].contains(mode) {
            var pixels = Data(repeating: 0, count: mode == .mismatchedMask ? 4 : 64)
            if mode != .emptyMask { pixels[0] = 1 }
            let detection = try VisionDetection(localID: "one", label: "object",
                box: PixelBox(x: mode == .outside ? 7 : 0, y: 0, width: 2, height: 2),
                mask: BinaryMask(width: mode == .mismatchedMask ? 2 : 8, height: mode == .mismatchedMask ? 2 : 8, pixels: pixels),
                confidence: nil, appearance: nil)
            detections = Array(repeating: detection, count: mode == .excessive ? 129 : mode == .duplicate ? 2 : 1)
        }
        return VisionOutput(identity: mode == .wrongModel ? try VisionIdentity(modelID: "foreign", version: "2", deployment: .local) : identity,
            context: context, imageSHA256: mode == .wrongDigest ? "foreign" : request.imageSHA256, detections: detections)
    }
}

// SAFETY: stateless suite; mutable port observations are isolated in VisionProbe.
final class FrameImportTests: XCTestCase, @unchecked Sendable {
    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private static func fixtureData() throws -> Data { try Data(contentsOf: root.appendingPathComponent("fixtures/providers/vision-synthetic.v1.json")) }
    private static func images() throws -> [Data] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        return try XCTUnwrap(root["frames"] as? [[String: Any]]).map { frame in
            try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(frame["imageBase64"] as? String)))
        }
    }
    private static func context() throws -> FrameContext {
        try FrameContext(actorID: UUID(), cameraID: UUID(), frameID: UUID(),
            timestamps: ObservationTimestamps(occurredAt: nil, observedAt: UTCInstant(secondsSince1970: 1_700_000_000.125),
                recordedAt: UTCInstant(secondsSince1970: 1_700_000_001.5), timeZone: IANATimeZone(identifier: "Europe/Paris")))
    }
    private static func consent(_ context: FrameContext, local: Bool = true, cloud: Bool = false,
                                foreign: Bool = false, expired: Bool = false) -> FrameImportConsent {
        FrameImportConsent(actorID: foreign ? UUID() : context.actorID, cameraID: context.cameraID,
            permitsLocalProcessing: local, permitsCloudTransfer: cloud, expiresAt: .now.advanced(by: .seconds(expired ? -1 : 30)))
    }
    private static func ingest(_ model: any VisionModel, context: FrameContext? = nil,
                               bytes: Data? = nil, deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(3))) async throws -> ImportedFrame {
        let context = try context ?? Self.context()
        return try await FrameImporter(model: model).ingest(bytes: bytes ?? images()[0], mediaType: "image/png",
            context: context, consent: consent(context), deadline: deadline)
    }
    private static func expect(_ code: VisionError, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(code)") }
        catch let error as VisionError { XCTAssertEqual(error, code) }
        catch { XCTFail("Unexpected unredacted error type") }
    }
    func testReplayBindsAllThreeSyntheticImagesToHostFrameAndTimestamps() async throws {
        let model = try SyntheticVisionModel(fixtureData: Self.fixtureData())
        for (index, image) in try Self.images().enumerated() {
            let context = try Self.context(), result = try await Self.ingest(model, context: context, bytes: image)
            XCTAssertEqual(result.context, context); XCTAssertNil(result.context.timestamps.occurredAt)
            XCTAssertEqual(result.identity.modelID, "fixture.vision"); XCTAssertEqual(result.identity.version, "1.0.0")
            XCTAssertTrue(result.synthetic); XCTAssertEqual(result.width, 8); XCTAssertEqual(result.height, 8)
            XCTAssertEqual(result.detections.count, 2)
            let red = try XCTUnwrap(result.detections.first { $0.localID == "red" })
            XCTAssertEqual(red.box.x, 1+2*index); XCTAssertEqual(red.appearance, [1,0])
            XCTAssertEqual(red.confidence?.value, 0.875)
            XCTAssertEqual(red.mask.pixels.filter { $0 == 1 }.count, 4)
        }
    }
    func testExactFixtureAndUnknownMediaCannotProduceFabricatedDetections() async throws {
        var fixture = try Self.fixtureData(); fixture.append(32)
        XCTAssertThrowsError(try SyntheticVisionModel(fixtureData: fixture))
        let model = try SyntheticVisionModel(fixtureData: Self.fixtureData())
        // A valid ancillary PNG chunk changes the image hash, not its pixels.
        var image = try Self.images()[0]
        let text = Data([0,0,0,3,116,69,88,116,97,0,98,0,0,0,0])
        var chunk = text; let crc = Self.crc32(Array(chunk[4..<11]))
        chunk.replaceSubrange(11..<15, with: [UInt8(crc>>24),UInt8((crc>>16)&255),UInt8((crc>>8)&255),UInt8(crc&255)])
        image.insert(contentsOf: chunk, at: image.count-12)
        _ = try PNGFrame(bytes: image, mediaType: "image/png")
        await Self.expect(.unavailable) { _ = try await Self.ingest(model, bytes: image) }
    }
    func testConsentActorCameraExpiryAndCloudRejectionPrecedeDispatch() async throws {
        let context = try Self.context(), bytes = try Self.images()[0]
        let probe = try VisionProbe(), cloud = try VisionProbe(deployment: .cloud)
        var consents = [Self.consent(context, local:false), Self.consent(context, foreign:true), Self.consent(context, expired:true)]
        consents.append(FrameImportConsent(actorID: context.actorID, cameraID: UUID(), permitsLocalProcessing:true,
            permitsCloudTransfer:false, expiresAt:.now.advanced(by:.seconds(5))))
        for consent in consents {
            await Self.expect(.consentRequired) {
                _ = try await FrameImporter(model: probe).ingest(bytes: bytes, mediaType:"image/png",context:context,consent:consent,deadline:.now.advanced(by:.seconds(3)))
            }
        }
        await Self.expect(.consentRequired) { _ = try await Self.ingest(cloud,context:context) }
        await Self.expect(.unavailable) {
            _ = try await FrameImporter(model: cloud).ingest(bytes: bytes, mediaType:"image/png", context:context,
                consent:Self.consent(context, cloud:true),deadline:.now.advanced(by:.seconds(3)))
        }
        let localCalls = await probe.calls, cloudCalls = await cloud.calls
        XCTAssertEqual(localCalls,0); XCTAssertEqual(cloudCalls,0)
    }
    func testPNGTypeSizeTruncationCRCDimensionsAndTrailingBytesFailBeforeDispatch() async throws {
        let probe = try VisionProbe(), context = try Self.context(), image = try Self.images()[0]
        var corrupt = image; corrupt[corrupt.count-1] ^= 1
        for bytes in [Data(), Data(image.prefix(40)), corrupt, image+Data([0])] {
            await Self.expect(.invalidMedia) { _ = try await Self.ingest(probe,context:context,bytes:bytes) }
        }
        await Self.expect(.mediaTooLarge) { _ = try await Self.ingest(probe,bytes:Data(repeating:0,count:PNGFrame.maximumBytes+1)) }
        await Self.expect(.invalidMedia) {
            _ = try await FrameImporter(model:probe).ingest(bytes:image,mediaType:"image/jpeg",context:context,
                consent:Self.consent(context),deadline:.now.advanced(by:.seconds(3)))
        }
        var excessiveDimensions = image
        excessiveDimensions.replaceSubrange(16..<20, with: [0,0,16,0])
        let crc = Self.crc32(Array(excessiveDimensions[12..<29]))
        excessiveDimensions.replaceSubrange(29..<33, with: [UInt8(crc>>24),UInt8((crc>>16)&255),UInt8((crc>>8)&255),UInt8(crc&255)])
        await Self.expect(.invalidMedia) { _ = try await Self.ingest(probe,bytes:excessiveDimensions) }
        let calls = await probe.calls; XCTAssertEqual(calls,0)
    }
    func testOutputIdentityContextDigestGeometryAndCountsCannotCrossBoundary() async throws {
        for mode in [VisionProbe.Mode.wrongActor,.wrongCamera,.wrongFrame,.wrongTime,.wrongModel,.wrongDigest,.excessive,.duplicate,.outside,.emptyMask,.mismatchedMask] {
            let probe = try VisionProbe(mode)
            await Self.expect(.invalidOutput) { _ = try await Self.ingest(probe) }
            let calls = await probe.calls; XCTAssertEqual(calls,1)
        }
    }
    func testEmptyDetectionsAndMissingConfidenceRemainExplicit() async throws {
        let empty = try await Self.ingest(VisionProbe())
        XCTAssertTrue(empty.detections.isEmpty); XCTAssertFalse(empty.synthetic)
        let result = try await Self.ingest(VisionProbe(.absentConfidence))
        XCTAssertEqual(result.detections.count,1); XCTAssertNil(result.detections[0].confidence)
        XCTAssertNil(result.detections[0].appearance)
    }
    func testMalformedNormalizedValuesAreRejected() throws {
        XCTAssertThrowsError(try PixelBox(x:Int.max,y:0,width:2,height:2))
        XCTAssertThrowsError(try BinaryMask(width:8,height:8,pixels:Data(repeating:2,count:64)))
        XCTAssertThrowsError(try BinaryMask(width:8,height:8,pixels:Data(repeating:0,count:63)))
        let box = try PixelBox(x:0,y:0,width:1,height:1), mask = try BinaryMask(width:1,height:1,pixels:Data([1]))
        for appearance in [[Double.nan],[Double.infinity],[2],Array(repeating:0,count:257)] {
            XCTAssertThrowsError(try VisionDetection(localID:"one",label:"label",box:box,mask:mask,confidence:nil,appearance:appearance))
        }
        XCTAssertThrowsError(try VisionIdentity(modelID:"secret\nvalue",version:"1",deployment:.cloud))
    }
    func testDeadlineCancelsAndJoinsTheProviderAndExpiredRequestDoesNotDispatch() async throws {
        let probe = try VisionProbe(.slow)
        await Self.expect(.timeout) { _ = try await Self.ingest(probe,deadline:.now.advanced(by:.milliseconds(100))) }
        let cancelled = await probe.cancelled; XCTAssertTrue(cancelled)
        let absent = try VisionProbe()
        await Self.expect(.timeout) { _ = try await Self.ingest(absent,deadline:.now.advanced(by:.seconds(-1))) }
        let calls = await absent.calls; XCTAssertEqual(calls,0)
    }
    func testExternalCancellationJoinsProviderAndPrivateFailureIsRedacted() async throws {
        let probe = try VisionProbe(.slow)
        let task = Task { try await Self.ingest(probe) }
        while await probe.calls == 0 { await Task.yield() }
        task.cancel()
        await Self.expect(.cancelled) { _ = try await task.value }
        let cancelled = await probe.cancelled; XCTAssertTrue(cancelled)
        await Self.expect(.unavailable) { _ = try await Self.ingest(VisionProbe(.privateError)) }
    }
    private static func crc32(_ bytes:[UInt8]) -> UInt32 {
        var crc:UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1 }
        }
        return crc ^ 0xffffffff
    }
}
