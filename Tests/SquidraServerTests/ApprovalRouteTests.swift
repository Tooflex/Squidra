import Foundation
import Hummingbird
import HummingbirdTesting
import SquidraDomain
import SquidraSecurity
import SquidraTools
import XCTest
@testable import SquidraServer

private actor RouteApprovals: ApprovalStore {
    private var record: ApprovalRecord
    init(_ record: ApprovalRecord) { self.record = record }
    func request(_ binding: ApprovalBinding, nowMilliseconds: Int64, ttlMilliseconds: Int64, deadline: ContinuousClock.Instant) throws -> ApprovalRecord {
        guard binding == record.binding else { throw ApprovalError.conflict };return record
    }
    func load(actorID: UUID, id: UUID, deadline: ContinuousClock.Instant) throws -> ApprovalObservation {
        guard actorID == record.binding.actorID,id == record.id else { throw ApprovalError.notFound }
        return ApprovalObservation(record:record,observedAtMilliseconds:record.requestedAtMilliseconds)
    }
    func resolve(_ original: ApprovalRecord, response: ApprovalResponse, approverID: UUID, nowMilliseconds: Int64, deadline: ContinuousClock.Instant) throws -> ApprovalRecord {
        guard original.version == record.version else { throw ApprovalError.conflict }
        let expired = nowMilliseconds >= record.expiresAtMilliseconds
        record = try ApprovalRecord(id:record.id,binding:record.binding,requestedAtMilliseconds:record.requestedAtMilliseconds,
            expiresAtMilliseconds:record.expiresAtMilliseconds,decision:expired ? .expired : response.decision,approverID:expired ? nil : approverID,
            decidedAtMilliseconds:nowMilliseconds,version:record.version+1)
        return record
    }
}
private actor RouteLedger: ActionLedgerStore {
    let record: ActionRecord
    private(set) var claims = 0
    init(_ record: ActionRecord) { self.record = record }
    func reserve(_ command: ActionCommand, deadline: ContinuousClock.Instant) throws -> ActionReservation {
        claims += 1;throw ActionLedgerError.unavailable
    }
    func load(actorID: UUID, id: UUID, deadline: ContinuousClock.Instant) throws -> ActionRecord {
        guard actorID == record.command.actorID,id == record.id else { throw ActionLedgerError.notFound };return record
    }
    func update(_ record: ActionRecord, to status: ActionStatus, result: ActionResult?, providerReference: String?, deadline: ContinuousClock.Instant) throws -> ActionRecord {
        claims += 1;throw ActionLedgerError.unavailable
    }
}

// SAFETY: no mutable test-instance state; fixture persistence is actor-isolated.
final class ApprovalRouteTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let record: ApprovalRecord, action: ActionRecord, ledger: RouteLedger, service: ApprovalCoordinator, token: String
    }
    private static func fixture(expired: Bool = false, alreadyApproved: Bool = false) throws -> Fixture {
        let actor = UUID(),run = UUID(),tool = try ToolID(namespace:"fixture",name:"write",version:"1.0.0")
        let command = try ActionCommand(actorID:actor,runID:run,tool:tool,idempotencyKey:"route-fixture",target:"entity:1",
            arguments:Data(#"{"exactInteger":9007199254740993,"note":"fixture"}"#.utf8),scope:["fixture:write"])
        let action = try ActionRecord(id:UUID(),command:command,status:.reserved,version:1,result:nil,providerReference:"private-receipt-never-echo")
        let binding = try ApprovalBinding(actorID:actor,runID:run,ledgerID:action.id,commandHash:command.fingerprint)
        let record = try ApprovalRecord(id:UUID(),binding:binding,requestedAtMilliseconds:1_700_000_000_000,expiresAtMilliseconds:1_700_000_600_000,
            decision:alreadyApproved ? .approved : .pending,approverID:alreadyApproved ? actor : nil,decidedAtMilliseconds:alreadyApproved ? 1_700_000_000_001 : nil,version:alreadyApproved ? 2 : 1)
        let clock = try FixedClock(instant:UTCInstant(secondsSince1970:expired ? 1_700_000_600 : 1_700_000_001),timeZone:IANATimeZone(identifier:"Etc/UTC"))
        let token = (0..<32).map{ _ in String(format:"%02x",UInt8.random(in:.min ... .max)) }.joined()
        return Fixture(record:record,action:action,ledger:RouteLedger(action),service:ApprovalCoordinator(store:RouteApprovals(record),clock:clock),token:token)
    }
    private static func app(_ fixture: Fixture, actor: UUID? = nil) throws -> some ApplicationProtocol {
        let configuration = try ServerConfiguration(environment:["SQUIDRA_PORT":"0","SQUIDRA_AUTH_TOKEN":fixture.token,
            "SQUIDRA_ACTOR_ID":(actor ?? fixture.record.binding.actorID).uuidString,"SQUIDRA_UI_ORIGIN":"http://localhost:3000",
            "SQUIDRA_DB_PORT":"5432","SQUIDRA_DB_USER":"squidra","SQUIDRA_DB_PASSWORD":String(repeating:"fixture",count:8),"SQUIDRA_DB_NAME":"squidra"])
        return ServerComposition.application(configuration:configuration,readiness:{ .ready },approvals:fixture.service,ledger:fixture.ledger)
    }
    private static func path(_ fixture: Fixture) -> String { "/api/v1/approvals/"+fixture.record.id.uuidString }
    private static func body(_ fixture: Fixture, decision: String = "approved") -> String {
        let digest = fixture.record.digest.map{String(format:"%02x",$0)}.joined()
        return "{\"schemaVersion\":\"1\",\"decision\":\"\(decision)\",\"digest\":\"\(digest)\"}"
    }
    func testApprovalReadsAndDecisionsRequireHostAuthentication() async throws {
        let fixture = try Self.fixture()
        try await Self.app(fixture).test(.router) { client in
            try await client.execute(uri:Self.path(fixture),method:.get) { XCTAssertEqual($0.status,.unauthorized) }
            try await client.execute(uri:Self.path(fixture)+"/decision",method:.post,body:.init(string:Self.body(fixture))) { XCTAssertEqual($0.status,.unauthorized) }
        }
    }
    func testPreviewPreservesExactArgumentsAndUTCExpiryWithoutPrivateReceipt() async throws {
        let fixture = try Self.fixture()
        try await Self.app(fixture).test(.router) { client in
            try await client.execute(uri:Self.path(fixture),method:.get,headers:[.authorization:"Bearer "+fixture.token]) { response in
                XCTAssertEqual(response.status,.ok);XCTAssertEqual(response.headers[.cacheControl],"no-store")
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(response.body.readableBytesView)) as? [String:Any])
                XCTAssertEqual(json["schemaVersion"] as? String,"1");XCTAssertEqual(json["decision"] as? String,"pending")
                XCTAssertEqual(json["argumentsJSON"] as? String,String(decoding:fixture.action.command.arguments,as:UTF8.self))
                XCTAssertEqual(json["commandFingerprint"] as? String,fixture.action.command.fingerprintHex)
                XCTAssertEqual(json["expiresAt"] as? String,"2023-11-14T22:23:20.000Z")
                XCTAssertFalse(String(buffer:response.body).contains("private-receipt"))
            }
        }
    }
    func testAuthenticatedDecisionReplaysAndDoesNotClaimOrExecuteAction() async throws {
        let fixture = try Self.fixture()
        try await Self.app(fixture).test(.live) { client in
            for _ in 0..<2 {
                try await client.execute(uri:Self.path(fixture)+"/decision",method:.post,
                    headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:.init(string:Self.body(fixture))) { response in
                    XCTAssertEqual(response.status,.ok)
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(response.body.readableBytesView)) as? [String:Any])
                    XCTAssertEqual(json["decision"] as? String,"approved");XCTAssertEqual(json["version"] as? Int,2)
                }
            }
        }
        let claims = await fixture.ledger.claims;XCTAssertEqual(claims,0)
    }
    func testOtherActorAndSpoofedHeaderCannotReadOrResolveApproval() async throws {
        let fixture = try Self.fixture(),other = UUID()
        try await Self.app(fixture,actor:other).test(.router) { client in
            try await client.execute(uri:Self.path(fixture),method:.get,headers:[.authorization:"Bearer "+fixture.token]) { XCTAssertEqual($0.status,.notFound) }
            try await client.execute(uri:Self.path(fixture)+"/decision",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:.init(string:Self.body(fixture))) { XCTAssertEqual($0.status,.notFound) }
            try await client.execute(uri:Self.path(fixture),method:.get,headers:[.authorization:"Bearer "+fixture.token,.init("X-Actor-ID")!:fixture.record.binding.actorID.uuidString]) { XCTAssertEqual($0.status,.forbidden) }
        }
    }
    func testClosedDecisionBodyRejectsClientIdentityTimestampDuplicatesAndUnknownValues() async throws {
        let fixture = try Self.fixture(),valid = Self.body(fixture)
        let invalid = [valid.replacingOccurrences(of:"\"1\"",with:"\"2\""),valid.replacingOccurrences(of:"\"approved\"",with:"true"),
            valid.dropLast()+",\"approverId\":\""+UUID().uuidString+"\"}",valid.dropLast()+",\"actorId\":\""+UUID().uuidString+"\"}",
            valid.dropLast()+",\"expiresAt\":\"2099\"}",valid.dropLast()+",\"decision\":\"denied\"}",
            Self.body(fixture,decision:"allow"),valid.replacingOccurrences(of:"schemaVersion",with:#"schema\u0056ersion"#),"[]"]
        try await Self.app(fixture).test(.router) { client in
            for body in invalid {
                try await client.execute(uri:Self.path(fixture)+"/decision",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:.init(string:String(body))) { response in
                    XCTAssertEqual(response.status,.badRequest)
                }
            }
            try await client.execute(uri:Self.path(fixture)+"/decision",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"text/plain"],body:.init(string:valid)) { XCTAssertEqual($0.status,.badRequest) }
            try await client.execute(uri:Self.path(fixture)+"/decision",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:.init(repeating:65,count:2_048)) { XCTAssertEqual($0.status,.contentTooLarge) }
        }
        let current = try await fixture.service.load(actorID:fixture.record.binding.actorID,id:fixture.record.id,deadline:.now.advanced(by:.seconds(1)))
        XCTAssertEqual(current.decision,.pending)
    }
    func testChangedDigestOppositeDecisionAndExpiredApprovalConflict() async throws {
        let fixture = try Self.fixture(),valid = Self.body(fixture),digest = fixture.record.digest.map{String(format:"%02x",$0)}.joined()
        try await Self.app(fixture).test(.router) { client in
            try await client.execute(uri:Self.path(fixture)+"/decision",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:.init(string:valid.replacingOccurrences(of:digest,with:String(repeating:"0",count:64)))) { XCTAssertEqual($0.status,.conflict) }
            try await client.execute(uri:Self.path(fixture)+"/decision",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:.init(string:valid)) { XCTAssertEqual($0.status,.ok) }
            try await client.execute(uri:Self.path(fixture)+"/decision",method:.post,headers:[.authorization:"Bearer "+fixture.token,.contentType:"application/json"],body:.init(string:Self.body(fixture,decision:"denied"))) { XCTAssertEqual($0.status,.conflict) }
        }
        for alreadyApproved in [false,true] {
            let expired = try Self.fixture(expired:true,alreadyApproved:alreadyApproved)
            try await Self.app(expired).test(.router) { client in
                try await client.execute(uri:Self.path(expired)+"/decision",method:.post,headers:[.authorization:"Bearer "+expired.token,.contentType:"application/json"],body:.init(string:Self.body(expired))) { XCTAssertEqual($0.status,.conflict) }
            }
        }
    }
}
