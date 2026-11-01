import Foundation
import SquidraDomain
import SquidraPerception
import XCTest
@testable import SquidraMeta

private actor SAMAdmissionBudget: MetaSAMAttemptBudget {
    let deny: Bool,delay: Duration
    private(set) var attempts: [UUID] = [],cancelled = false
    init(deny: Bool = false, delay: Duration = .zero) { self.deny = deny;self.delay = delay }
    func reserveSAM(attemptID: UUID, frameID: UUID, deadline: ContinuousClock.Instant) async throws {
        attempts.append(attemptID)
        if deny { throw VisionError.unavailable }
        do { try await Task.sleep(for:delay) } catch { cancelled = true;throw error }
    }
}
private actor SAMAdmissionTransport: MetaResponsesTransport {
    let text: String
    private(set) var calls = 0
    init(text: String) { self.text = text }
    func post(_ body: Data, maximumResponseBytes: Int, deadline: ContinuousClock.Instant) async throws -> MetaHTTPResponse {
        calls += 1
        return MetaHTTPResponse(status:200,contentType:"application/json",body:try JSONSerialization.data(withJSONObject:["object":"response","model":"sam-3.1","status":"completed","output":[["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":text]]]]]))
    }
}
private struct WrongCloudModel: VisionModel {
    let identity = try! VisionIdentity(modelID:"unqualified",version:"1",deployment:.cloud)
    func detect(_ request:VisionRequest) throws -> VisionOutput { throw VisionError.invalidOutput }
}
final class SAMCloudAdmissionTests: XCTestCase, @unchecked Sendable {
    private var root: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func image() throws -> Data { try Data(contentsOf:root.appendingPathComponent("fixtures/providers/sam-red-square.png")) }
    private func transport() throws -> SAMAdmissionTransport {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("fixtures/providers/sam-image-live.v1.json"))) as? [String:Any])
        let report = try XCTUnwrap(object["report"] as? [String:Any]);return SAMAdmissionTransport(text:try XCTUnwrap(report["segmentationText"] as? String))
    }
    private func context() throws -> FrameContext {
        try FrameContext(actorID:UUID(),cameraID:UUID(),frameID:UUID(),timestamps:ObservationTimestamps(occurredAt:nil,observedAt:UTCInstant(secondsSince1970:1),recordedAt:UTCInstant(secondsSince1970:2),timeZone:IANATimeZone(identifier:"UTC")))
    }
    private func consent(_ context: FrameContext, cloud: Bool = true, expires: ContinuousClock.Instant = .now.advanced(by:.seconds(10))) -> FrameImportConsent {
        FrameImportConsent(actorID:context.actorID,cameraID:context.cameraID,permitsLocalProcessing:true,permitsCloudTransfer:cloud,expiresAt:expires)
    }
    func testCapturedSAMOutputPassesOnlyAfterAdmissionAndRetainsCloudProvenance() async throws {
        let transport = try transport(),budget = SAMAdmissionBudget(),context = try context()
        let importer = try FrameImporter(model:MetaSAMVisionModel(concept:"red square",transport:transport),cloudAdmission:MetaSAMCloudAdmission(budget:budget))
        let output = try await importer.ingest(bytes:image(),mediaType:"image/png",context:context,consent:consent(context),deadline:.now.advanced(by:.seconds(10)))
        XCTAssertEqual(output.context,context);XCTAssertEqual(output.identity.deployment,.cloud);XCTAssertFalse(output.synthetic)
        XCTAssertEqual(output.detections.count,1);XCTAssertEqual(output.detections[0].mask.pixels.filter { $0 == 1 }.count,64849)
        XCTAssertEqual(output.imageSHA256,"62201c030c004452926e53f8f9c3659bfdcf22519812552c94aaa26e700993dc")
        let calls = await transport.calls,attempts = await budget.attempts;XCTAssertEqual(calls,1);XCTAssertEqual(attempts.count,1)
    }
    func testConsentAndMalformedMediaRejectBeforeAdmissionOrProvider() async throws {
        let transport = try transport(),budget = SAMAdmissionBudget(),context = try context()
        let importer = try FrameImporter(model:MetaSAMVisionModel(concept:"red square",transport:transport),cloudAdmission:MetaSAMCloudAdmission(budget:budget))
        for permit in [consent(context,cloud:false),consent(try self.context()),consent(context,expires:.now.advanced(by:.seconds(-1)))] {
            do { _ = try await importer.ingest(bytes:image(),mediaType:"image/png",context:context,consent:permit,deadline:.now.advanced(by:.seconds(5)));XCTFail() }
            catch { XCTAssertEqual(error as? VisionError,.consentRequired) }
        }
        do { _ = try await importer.ingest(bytes:Data(),mediaType:"image/png",context:context,consent:consent(context),deadline:.now.advanced(by:.seconds(5)));XCTFail() }
        catch { XCTAssertEqual(error as? VisionError,.invalidMedia) }
        let calls = await transport.calls,attempts = await budget.attempts;XCTAssertEqual(calls,0);XCTAssertTrue(attempts.isEmpty)
    }
    func testNoAdmissionAndBudgetDenialDoNotDispatch() async throws {
        let transport = try transport(),budget = SAMAdmissionBudget(deny:true),context = try context(),model = try MetaSAMVisionModel(concept:"red square",transport:transport)
        for importer in [FrameImporter(model:model),FrameImporter(model:model,cloudAdmission:MetaSAMCloudAdmission(budget:budget))] {
            do { _ = try await importer.ingest(bytes:image(),mediaType:"image/png",context:context,consent:consent(context),deadline:.now.advanced(by:.seconds(5)));XCTFail() }
            catch { XCTAssertEqual(error as? VisionError,.unavailable) }
        }
        let calls = await transport.calls,attempts = await budget.attempts;XCTAssertEqual(calls,0);XCTAssertEqual(attempts.count,1)
    }
    func testUnknownModelAndOversizedPNGEnvelopeRejectBeforeBudget() async throws {
        let budget = SAMAdmissionBudget(),context = try context()
        let wrong = FrameImporter(model:WrongCloudModel(),cloudAdmission:MetaSAMCloudAdmission(budget:budget))
        do { _ = try await wrong.ingest(bytes:image(),mediaType:"image/png",context:context,consent:consent(context),deadline:.now.advanced(by:.seconds(5)));XCTFail() }
        catch { XCTAssertEqual(error as? VisionError,.unavailable) }
        // Envelope-only quota fixture; it is never decompressed or dispatched.
        var bytes = try image();bytes.replaceSubrange(16..<20,with:[0,0,8,0])
        var crc: UInt32 = .max
        for byte in bytes[12..<29] { crc ^= UInt32(byte);for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }
        crc ^= .max;bytes.replaceSubrange(29..<33,with:(0..<4).map { UInt8((crc >> (24-$0*8)) & 255) })
        let transport = try transport(),importer = try FrameImporter(model:MetaSAMVisionModel(concept:"red square",transport:transport),cloudAdmission:MetaSAMCloudAdmission(budget:budget))
        do { _ = try await importer.ingest(bytes:bytes,mediaType:"image/png",context:context,consent:consent(context),deadline:.now.advanced(by:.seconds(5)));XCTFail() }
        catch { XCTAssertEqual(error as? VisionError,.mediaTooLarge) }
        let calls = await transport.calls,attempts = await budget.attempts;XCTAssertEqual(calls,0);XCTAssertTrue(attempts.isEmpty)
    }
    func testAdmissionDeadlineAndCancellationJoinBeforeAnyDispatch() async throws {
        for callerCancel in [false,true] {
            let transport = try transport(),budget = SAMAdmissionBudget(delay:.seconds(10)),context = try context(),bytes = try image()
            let importer = try FrameImporter(model:MetaSAMVisionModel(concept:"red square",transport:transport),cloudAdmission:MetaSAMCloudAdmission(budget:budget))
            let permit = consent(context,expires:.now.advanced(by:callerCancel ? .seconds(5) : .milliseconds(50)))
            let task = Task { try await importer.ingest(bytes:bytes,mediaType:"image/png",context:context,consent:permit,deadline:.now.advanced(by:.seconds(5))) }
            if callerCancel {
                let end = ContinuousClock.now.advanced(by:.seconds(1))
                while await budget.attempts.isEmpty,ContinuousClock.now < end { try await Task.sleep(for:.milliseconds(1)) };task.cancel()
            }
            do { _ = try await task.value;XCTFail() } catch { XCTAssertEqual(error as? VisionError,callerCancel ? .cancelled : .timeout) }
            let calls = await transport.calls,cancelled = await budget.cancelled,attempts = await budget.attempts
            XCTAssertEqual(calls,0);XCTAssertTrue(cancelled);XCTAssertEqual(attempts.count,1)
        }
    }
}
