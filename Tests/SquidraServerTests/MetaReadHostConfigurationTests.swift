import Foundation
import SquidraMeta
import SquidraCognition
import SquidraDomain
import XCTest
@testable import SquidraServer
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private actor ConfiguredMetaTransport: MetaResponsesTransport {
    private(set) var calls = 0
    func post(_ body: Data, maximumResponseBytes: Int, deadline: ContinuousClock.Instant) async throws -> MetaHTTPResponse {
        calls += 1
        let request = try JSONSerialization.jsonObject(with:body) as! [String:Any]
        return MetaHTTPResponse(status:200,contentType:"application/json",body:try JSONSerialization.data(withJSONObject:[
            "id":"resp_fixture","object":"response","model":request["model"]!,"status":"completed",
            "output":[["type":"message","role":"assistant","status":"completed","content":[["type":"output_text","text":"{\"claims\":[]}"]]]],
            "usage":["input_tokens":10,"output_tokens":20,"total_tokens":30]]))
    }
}
final class MetaReadHostConfigurationTests: XCTestCase, @unchecked Sendable {
    private let now: Double = 1_793_500_000
    private func clock(_ time: Double? = nil) throws -> FixedClock {
        try FixedClock(instant:UTCInstant(secondsSince1970:time ?? now),timeZone:IANATimeZone(identifier:"UTC"))
    }
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squidra-meta-host-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        addTeardownBlock { try FileManager.default.removeItem(at:dir) };return dir
    }
    private func environment(_ dir: URL) -> [String:String] {
        ["SQUIDRA_META_CLOUD_CONSENT":"1","SQUIDRA_META_MODEL":"spark","SQUIDRA_META_BUDGET_DIRECTORY":dir.path,
         "MODEL_API_KEY":"fixture-key-not-a-secret","SQUIDRA_META_ENTITY_IDS":UUID().uuidString.lowercased()]
    }
    private func host(_ env: [String:String], imported: Bool = false, time: Double? = nil, transport: ConfiguredMetaTransport = ConfiguredMetaTransport()) throws -> ReadHostConfiguration {
        try MetaReadHostConfiguration.read(environment:env,allowsImportedEntities:imported,clock:clock(time),transportFactory:{ _ in transport })
    }
    private func baseEnvironment() -> [String:String] {
        ["SQUIDRA_AUTH_TOKEN":String(repeating:"a",count:64),"SQUIDRA_ACTOR_ID":UUID().uuidString,
         "SQUIDRA_UI_ORIGIN":"http://localhost:3000","SQUIDRA_DB_PORT":"5432","SQUIDRA_DB_USER":"squidra",
         "SQUIDRA_DB_PASSWORD":String(repeating:"fixture",count:6),"SQUIDRA_DB_NAME":"squidra"]
    }
    func testKeyAloneDoesNotActivateAndExplicitProfileBuildsActualAdapter() throws {
        let env = environment(try directory());var all = baseEnvironment().merging(env,uniquingKeysWith:{ _,b in b })
        XCTAssertNil(try ServerConfiguration(environment:all,clock:clock()).configuredReadHost)
        all["SQUIDRA_PROFILE"] = "meta-qualification"
        let configured = try XCTUnwrap(ServerConfiguration(environment:all,clock:clock()).configuredReadHost)
        XCTAssertTrue(configured.models.first is MetaLanguageModel);XCTAssertTrue(configured.cloudConsent)
        XCTAssertEqual(configured.maximumCostMicroUSD,20_000_000);XCTAssertEqual(configured.maximumOutputTokens,2048)
        XCTAssertEqual(configured.budget.retries,0)
        XCTAssertEqual(configured.entities.first?.id.uuidString.lowercased(),env["SQUIDRA_META_ENTITY_IDS"])
        let configuration = try ServerConfiguration(environment:all,clock:clock())
        XCTAssertThrowsError(try ServerComposition.live(configuration:configuration,readHost:configured))
        all["SQUIDRA_META_MODEL"] = "wonder"
        XCTAssertEqual(try ServerConfiguration(environment:all,clock:clock()).configuredReadHost?.models.first?.descriptor.id,"muse-wonder-1.0")
        all["SQUIDRA_PROFILE"] = "meta";XCTAssertThrowsError(try ServerConfiguration(environment:all,clock:clock()))
    }
    func testConsentModelCredentialBudgetAndScopeAreRequired() throws {
        let env = environment(try directory())
        for name in ["SQUIDRA_META_CLOUD_CONSENT","SQUIDRA_META_MODEL","SQUIDRA_META_BUDGET_DIRECTORY","MODEL_API_KEY","SQUIDRA_META_ENTITY_IDS"] {
            var missing = env;missing.removeValue(forKey:name);XCTAssertThrowsError(try host(missing))
        }
        for (name,value) in [("SQUIDRA_META_CLOUD_CONSENT","true"),("SQUIDRA_META_MODEL","unknown"),("MODEL_API_KEY","bad\nkey"),("SQUIDRA_META_BUDGET_DIRECTORY","relative"),("SQUIDRA_META_ENTITY_IDS","bad-id")] {
            var invalid = env;invalid[name] = value;XCTAssertThrowsError(try host(invalid))
        }
        var duplicate = env;duplicate["SQUIDRA_META_ENTITY_IDS"] = env["SQUIDRA_META_ENTITY_IDS"]!+","+env["SQUIDRA_META_ENTITY_IDS"]!
        XCTAssertThrowsError(try host(duplicate))
    }
    func testImportedScopeIsExplicitAndExpiryRequiresFullRunWindow() throws {
        var env = environment(try directory());env.removeValue(forKey:"SQUIDRA_META_ENTITY_IDS")
        XCTAssertThrowsError(try host(env))
        let imported = try host(env,imported:true);XCTAssertTrue(imported.allowSyntheticImportedEntities);XCTAssertTrue(imported.entities.isEmpty)
        XCTAssertThrowsError(try host(env,imported:true,time:MetaFileAttemptBudget.validUntilSeconds-100))
        XCTAssertThrowsError(try host(env,imported:true,time:MetaFileAttemptBudget.validUntilSeconds))
    }
    func testPrivateKeyFileLoadsButAmbiguityPermissionsSymlinkAndFIFOReject() throws {
        let dir = try directory(),path = dir.appendingPathComponent("key")
        try Data("fixture-file-key".utf8).write(to:path)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        var env = environment(dir);env["MODEL_API_KEY_FILE"] = path.path
        XCTAssertThrowsError(try host(env));env.removeValue(forKey:"MODEL_API_KEY")
        XCTAssertNoThrow(try host(env))
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:path.path);XCTAssertThrowsError(try host(env))
        try FileManager.default.moveItem(at:path,to:dir.appendingPathComponent("actual"))
        try FileManager.default.createSymbolicLink(atPath:path.path,withDestinationPath:"actual");XCTAssertThrowsError(try host(env))
        try FileManager.default.removeItem(at:path);XCTAssertEqual(mkfifo(path.path,mode_t(0o600)),0);XCTAssertThrowsError(try host(env))
    }
    func testConfiguredAdapterReservesSharedLedgerBeforeEachCallAndRejectsExhaustion() async throws {
        let dir = try directory(),path = dir.appendingPathComponent("live-budget.json"),transport = ConfiguredMetaTransport()
        var attempts: [[String:Any]] = (0..<8).map { _ in ["id":UUID().uuidString.lowercased(),"model":"sam-3.1","reservedEURCents":1000,"status":"reserved","report":NSNull()] }
        let ledger: [String:Any] = ["schemaVersion":1,"authorizedEURCents":10000,"reservationEURCents":1000,"fx":["usdPerEUR":"1.1172","date":"2026-10-30","source":"ECB"],"validUntil":"2026-11-02T00:00:00+00:00","attempts":attempts]
        try JSONSerialization.data(withJSONObject:ledger).write(to:path);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        let configured = try host(environment(dir),transport:transport),model = try XCTUnwrap(configured.models.first)
        let input = ModelRequest(id:UUID(),messages:[.init(role:.user,content:"Fixture")],cloudConsent:configured.cloudConsent,
            maximumCostMicroUSD:configured.maximumCostMicroUSD,maximumOutputTokens:configured.maximumOutputTokens,deadline:try UTCInstant(secondsSince1970:now+5))
        let planner = try ReadPlanner(router:ModelRouter(models:configured.models,clock:clock()),clock:clock())
        do {
            _ = try await planner.plan(question:"Fixture",scope:ReadPlanningScope(entities:configured.entities),requestID:UUID(),
                options:ReadPlanningOptions(cloudConsent:configured.cloudConsent,maximumCostMicroUSD:configured.maximumCostMicroUSD,
                    maximumOutputTokens:configured.maximumOutputTokens,deadline:UTCInstant(secondsSince1970:now+5)))
            XCTFail("The fake answer is intentionally not a valid plan")
        } catch { XCTAssertEqual(error as? ReadPlanningError,.invalidProposal) }
        _ = try await model.generate(input)
        do { _ = try await model.generate(input);XCTFail() } catch { XCTAssertEqual(error as? ModelRoutingError,.budgetExceeded) }
        let calls = await transport.calls;XCTAssertEqual(calls,2)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any])
        attempts = try XCTUnwrap(stored["attempts"] as? [[String:Any]]);XCTAssertEqual(attempts.count,10)
    }
}
