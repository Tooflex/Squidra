import Crypto
import Foundation
import JSONSchema
import SquidraDomain
import XCTest

// SAFETY: stateless suite; all mutable fixture copies are local to each test.
final class ProviderContractTests: XCTestCase, @unchecked Sendable {
    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private static func data(_ path: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(path)) }
    private static func fixture() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data("fixtures/providers/vision-synthetic.v1.json")) as? [String: Any])
    }
    private static func schema() throws -> Schema {
        let bytes = try data("Schemas/providers/vision-synthetic.v1.json")
        _ = try JSONDocument(bytes)
        return try Schema(rawSchema: JSONValue.parse(bytes), context: .init(dialect: .draft2020_12, remoteSchema: [:]))
    }
    private static func accepts(_ object: [String: Any]) throws -> Bool {
        let bytes = try JSONSerialization.data(withJSONObject: object)
        _ = try JSONDocument(bytes)
        return try schema().validate(JSONValue.parse(bytes)).isValid
    }
    private static func frames(_ object: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(object["frames"] as? [[String: Any]])
    }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    /// Cross-field checks supplement JSON Schema; this is a test contract, not a live decoder.
    private static func consistent(_ object: [String: Any]) throws -> Bool {
        guard try accepts(object) else { return false }
        let frames = try frames(object)
        guard Set(frames.compactMap { $0["caseId"] as? String }).count == frames.count else { return false }
        for frame in frames {
            guard let image = (frame["imageBase64"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  digest(image) == frame["imageSHA256"] as? String,
                  image.count >= 33,
                  Array(image.prefix(8)) == [137,80,78,71,13,10,26,10],
                  Array(image[12..<16]) == Array("IHDR".utf8),
                  Array(image[16..<24]) == [0,0,0,8,0,0,0,8], image[24] == 8, image[25] == 2,
                  let detections = frame["detections"] as? [[String: Any]],
                  Set(detections.compactMap { $0["localId"] as? String }).count == detections.count else { return false }
            for detection in detections {
                guard let box = detection["box"] as? [String: Int], let x = box["x"], let y = box["y"],
                      let w = box["width"], let h = box["height"], x+w <= 8, y+h <= 8,
                      let mask = detection["mask"] as? String else { return false }
                let expected = (0..<64).map { index in x <= index%8 && index%8 < x+w && y <= index/8 && index/8 < y+h ? "1" : "0" }.joined()
                guard mask == expected else { return false }
            }
        }
        return true
    }
    func testClosedSchemaIsValidAndSyntheticFixtureConforms() throws {
        XCTAssertTrue(try Self.schema().validateAgainstMetaSchema().isValid)
        XCTAssertTrue(try Self.accepts(Self.fixture()))
        XCTAssertTrue(try Self.consistent(Self.fixture()))
    }
    func testSyntheticProvenanceCannotBePromotedToLiveOrProviderOutput() throws {
        for (key, value) in [("schemaVersion", "2" as Any), ("liveQualified", true),
                              ("provenance", "captured_provider_response"), ("modelId", "sam-3.1"),
                              ("modelVersion", "latest"), ("confidenceMeaning", "measured_probability"),
                              ("actorId", UUID().uuidString)] {
            var object = try Self.fixture(); object[key] = value
            XCTAssertFalse(try Self.accepts(object), key)
        }
    }
    func testConfidenceGeometryAndUnknownFieldsAreRejected() throws {
        for (key, value) in [("confidence", -0.01 as Any), ("confidence", 1.01), ("mask", "101"),
                              ("mask", String(repeating: "x", count: 64)), ("appearance", [1, 0, 0]),
                              ("actorId", UUID().uuidString), ("box", ["x": -1,"y": 1,"width": 2,"height": 2])] {
            var object = try Self.fixture(), frames = try Self.frames(object)
            var detections = try XCTUnwrap(frames[0]["detections"] as? [[String: Any]])
            detections[0][key] = value; frames[0]["detections"] = detections; object["frames"] = frames
            XCTAssertFalse(try Self.accepts(object), key)
        }
    }
    func testCrossFieldImageDigestBoundsMaskAndIdentityCorruptionFail() throws {
        for mode in 0..<5 {
            var object = try Self.fixture(), frames = try Self.frames(object)
            var detections = try XCTUnwrap(frames[0]["detections"] as? [[String: Any]])
            switch mode {
            case 0: frames[0]["imageSHA256"] = String(repeating: "0", count: 64)
            case 1: detections[0]["box"] = ["x":7,"y":1,"width":2,"height":2]
            case 2: detections[0]["mask"] = String(repeating: "0", count: 64)
            case 3: detections[1]["localId"] = detections[0]["localId"]
            default: frames[1]["caseId"] = frames[0]["caseId"]
            }
            frames[0]["detections"] = detections; object["frames"] = frames
            XCTAssertFalse(try Self.consistent(object), "mode \(mode)")
        }
    }
    func testSequenceSeparatesMotionFromStationaryAppearance() throws {
        let frames = try Self.frames(Self.fixture())
        var redX: [Int] = [], blueX: [Int] = []
        for frame in frames {
            let detections = try XCTUnwrap(frame["detections"] as? [[String: Any]])
            let red = try XCTUnwrap(detections.first { $0["localId"] as? String == "red" })
            let blue = try XCTUnwrap(detections.first { $0["localId"] as? String == "blue" })
            redX.append(try XCTUnwrap((red["box"] as? [String: Int])?["x"]))
            blueX.append(try XCTUnwrap((blue["box"] as? [String: Int])?["x"]))
            XCTAssertEqual(red["appearance"] as? [Int], [1,0]); XCTAssertEqual(blue["appearance"] as? [Int], [0,1])
        }
        XCTAssertEqual(redX, [1,3,5]); XCTAssertEqual(blueX, [1,1,1])
    }
    func testProviderMatrixRecordsDocumentationWithoutClaimingLiveQualification() throws {
        let matrix = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.data("fixtures/providers/qualification.v1.json")) as? [String: Any])
        XCTAssertEqual(matrix["schemaVersion"] as? String, "1")
        XCTAssertEqual(matrix["defaultProfile"] as? String, "offline")
        XCTAssertEqual(matrix["liveQualified"] as? Bool, false)
        XCTAssertEqual(matrix["inferenceCallsMade"] as? Int, 0)
        let providers = try XCTUnwrap(matrix["providers"] as? [[String: Any]])
        XCTAssertEqual(Set(providers.compactMap { $0["family"] as? String }), ["Spark","Wonder","Glimmer","SAM"])
        XCTAssertEqual(providers.count, 4)
        for provider in providers {
            XCTAssertEqual(provider["documentationStatus"] as? String, "verified")
            for status in ["accountAccess", "runtimeCompatibility", "liveInference"] { XCTAssertEqual(provider[status] as? String, "untested") }
            XCTAssertEqual(provider["liveQualified"] as? Bool, false)
            XCTAssertFalse(try XCTUnwrap(provider["blockers"] as? [String]).isEmpty)
        }
    }
    func testCurrentMatrixLinksBoundedQualificationToActualEvidenceWithoutPromotingUnknowns() throws {
        func object(_ path: String) throws -> [String:Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with:Self.data("fixtures/providers/"+path)) as? [String:Any])
        }
        let matrix = try object("qualification.v2.json")
        XCTAssertEqual(matrix["schemaVersion"] as? String,"2");XCTAssertEqual(matrix["defaultProfile"] as? String,"offline")
        XCTAssertEqual(matrix["productionQualified"] as? Bool,false)
        let providers = try XCTUnwrap(matrix["providers"] as? [[String:Any]])
        XCTAssertEqual(Set(providers.compactMap { $0["family"] as? String }),["Spark","Wonder","Glimmer","SAM"])
        let initial = try XCTUnwrap(object("meta-text-live.v1.json")["reports"] as? [[String:Any]])
        let sam = try XCTUnwrap(object("sam-image-live.v1.json")["report"] as? [String:Any])
        let question = try object("meta-question-live.v1.json"),chain = try object("sam-meta-question-live.v1.json")
        for text in initial { XCTAssertEqual(text["outcome"] as? String,"passed");XCTAssertEqual(text["httpStatus"] as? Int,200) }
        XCTAssertEqual(sam["outcome"] as? String,"passed");XCTAssertEqual(sam["httpStatus"] as? Int,200)
        XCTAssertEqual(question["outcome"] as? String,"grounded_answer_verified")
        XCTAssertEqual(question["harnessOutcome"] as? String,"failed") // Preserve the earlier keyboard-harness failure.
        XCTAssertEqual(chain["outcome"] as? String,"passed");XCTAssertEqual(chain["harnessOutcome"] as? String,"passed")
        XCTAssertEqual(chain["sqlVerification"] as? String,"passed")
        let oldUsage = try XCTUnwrap(question["modelUsage"] as? [[String:Any]]),newUsage = try XCTUnwrap(chain["modelUsage"] as? [[String:Any]])
        let verifiedCalls = initial.count + 1 + oldUsage.count + newUsage.count + 1
        XCTAssertEqual(matrix["verifiedInferenceCalls"] as? Int,verifiedCalls)
        XCTAssertEqual(matrix["uncertainReservedCalls"] as? Int,1)
        XCTAssertEqual(matrix["reservedEURCents"] as? Int,chain["reservedEURCentsAfter"] as? Int)
        XCTAssertEqual(matrix["invoicedCost"] as? String,"not_reconciled")
        let allowedEvidence:Set<String> = ["meta-text-live.v1.json","sam-image-live.v1.json","meta-question-live.v1.json","sam-meta-question-live.v1.json","sources.v1.json"]
        for provider in providers {
            let family = try XCTUnwrap(provider["family"] as? String),hosted = family != "Glimmer"
            XCTAssertEqual(provider["productionQualified"] as? Bool,false)
            XCTAssertEqual(provider["liveInference"] as? String,hosted ? "verified_bounded" : "untested")
            XCTAssertEqual(provider["accountAccess"] as? String,hosted ? "verified" : "untested")
            XCTAssertEqual(provider["accountRetention"] as? String,"untested")
            let runtime = try XCTUnwrap(provider["runtimeCompatibility"] as? [String:String]);XCTAssertEqual(runtime["Linux"],"untested")
            let evidence = try XCTUnwrap(provider["evidence"] as? [String]);XCTAssertFalse(evidence.isEmpty)
            for file in evidence { XCTAssertTrue(allowedEvidence.contains(file));_ = try object(file) }
            if family == "Spark" || family == "Wonder" {
                XCTAssertTrue(initial.contains { $0["model"] as? String == provider["documentedId"] as? String })
                XCTAssertTrue(evidence.contains("meta-text-live.v1.json"))
            } else if family == "SAM" {
                let receipt = try XCTUnwrap(chain["receipt"] as? [String:Any])
                XCTAssertEqual(receipt["deployment"] as? String,"cloud");XCTAssertEqual(receipt["modelVersion"] as? String,"alias:sam-3.1")
                XCTAssertTrue(evidence.contains("sam-image-live.v1.json"));XCTAssertTrue(evidence.contains("sam-meta-question-live.v1.json"))
            } else {
                XCTAssertEqual(provider["verifiedScope"] as? [String],[])
                XCTAssertTrue(provider["hostedEndpoint"] is NSNull)
            }
        }
    }
    func testSourceObservationsHaveDigestsAndSeparateImmutableRevisions() throws {
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.data("fixtures/providers/sources.v1.json")) as? [String: Any])
        let sources = try XCTUnwrap(catalog["sources"] as? [[String: Any]])
        XCTAssertEqual(Set(sources.compactMap { $0["id"] as? String }).count, sources.count)
        XCTAssertGreaterThanOrEqual(sources.count, 11)
        for source in sources {
            XCTAssertEqual(source["observedOn"] as? String, "2026-10-31")
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(source["url"] as? String)))
            XCTAssertEqual(url.scheme, "https")
            XCTAssertTrue(["dev.meta.ai", "api.github.com", "huggingface.co"].contains(url.host ?? ""))
            XCTAssertNil(url.query); XCTAssertNil(url.user); XCTAssertNil(url.password)
            XCTAssertNotNil((source["sha256"] as? String)?.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
            XCTAssertGreaterThan(try XCTUnwrap(source["bytes"] as? Int), 0)
            if (source["id"] as? String)?.hasSuffix("weights") == true || source["id"] as? String == "sam-source" {
                XCTAssertNotNil((source["revision"] as? String)?.range(of: "^[0-9a-f]{40}$", options: .regularExpression))
            } else { XCTAssertNil(source["revision"]) }
        }
    }
}
