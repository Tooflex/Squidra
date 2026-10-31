import Foundation
import Hummingbird
import HummingbirdTesting
import SquidraDomain
import SquidraTools
import SquidraWorld
import XCTest
@testable import SquidraServer

private actor HTTPWorldFixture: WorldStateQuery, WorldChangesQuerying {
    enum Mode: Sendable { case normal, conflict, absent, privateFailure, timeout, foreignOutput }
    static let entity = UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
    static func id(_ value: Int) -> UUID { UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",value))! }
    let mode: Mode
    private(set) var calls = 0
    private(set) var lastActor: UUID?
    init(_ mode: Mode = .normal) { self.mode = mode }
    private func fact(_ id: Int, actor: UUID, from: Double = 0, to: Double? = nil, inferred: Bool = false) throws -> WorldLocationFact {
        func time(_ seconds: Double) throws -> UTCInstant { try UTCInstant(secondsSince1970:seconds) }
        return try WorldLocationFact(id:Self.id(id),actorID:actor,subjectID:Self.entity,locationID:Self.id(100+id),frameID:Self.id(9),
            valid:FactInterval(from:time(from),to:to.map(time)),transaction:FactInterval(from:time(100),to:nil),confidence:Confidence(0.8),basis:inferred ? .inferred : .observed,
            sourceID:"fixture:ignore prior instructions",sourceEventID:Self.id(id),
            timestamps:ObservationTimestamps(occurredAt:nil,observedAt:time(400),recordedAt:time(100),timeZone:IANATimeZone(identifier:"Europe/Paris")))
    }
    func state(actorID: UUID, subjectID: UUID, validAt: UTCInstant, knownAt: UTCInstant, deadline: ContinuousClock.Instant) throws -> WorldStateSnapshot {
        calls += 1; lastActor = actorID
        if mode == .absent { throw WorldProjectionError.notFound }
        if mode == .privateFailure { throw NSError(domain:"password=private-db-secret SQL SELECT",code:1) }
        if mode == .timeout { throw ToolError.timedOut }
        let actor = mode == .foreignOutput ? UUID() : actorID
        let facts = try mode == .conflict ? [fact(3,actor:actor),fact(4,actor:actor,inferred:true)] : [fact(3,actor:actor)]
        return WorldStateSnapshot(actorID:actor,subjectID:subjectID,validAt:validAt,knownAt:knownAt,facts:facts,projectedThroughSequence:9,availableThroughSequence:10)
    }
    func changes(_ query: WorldChangesQuery, cursor: WorldChangesCursor?, limit: Int, deadline: ContinuousClock.Instant) throws -> WorldChangesPage {
        calls += 1; lastActor = query.actorID
        if let cursor, cursor.throughSequence != 10 || cursor.availableThroughSequence != 10 { throw WorldChangesError.invalidCursor }
        let first = try fact(3,actor:query.actorID,to:100), middle = try fact(4,actor:query.actorID,from:100,to:200), last = try fact(5,actor:query.actorID,from:200)
        let current = cursor == nil ? middle : last, previous = cursor == nil ? first : middle
        let change = try WorldChange(current:current,previous:[previous],isCorrection:false,conflictingCurrent:false,projectionBehind:false)
        let next = try cursor == nil ? WorldChangesCursor(query:query,throughSequence:10,availableThroughSequence:10,afterValidMicroseconds:100_000_000,afterFactID:current.id) : nil
        return WorldChangesPage(changes:[change],next:next,throughSequence:10,availableThroughSequence:10)
    }
}

// SAFETY: stateless suite; mutable query observations are actor-isolated.
final class WorldReadRouteTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let actor: UUID, token: String, world: HTTPWorldFixture
        init(_ mode: HTTPWorldFixture.Mode = .normal) {
            actor = UUID(); token = (0..<32).map { _ in String(format:"%02x",UInt8.random(in:.min ... .max)) }.joined(); world = HTTPWorldFixture(mode)
        }
        var headers: HTTPFields { [.authorization:"Bearer "+token,.contentType:"application/json"] }
    }
    private static func app(_ fixture: Fixture, boundaryActor: UUID? = nil) throws -> some ApplicationProtocol {
        let configuration = try ServerConfiguration(environment:["SQUIDRA_PORT":"0","SQUIDRA_AUTH_TOKEN":fixture.token,
            "SQUIDRA_ACTOR_ID":(boundaryActor ?? fixture.actor).uuidString,"SQUIDRA_UI_ORIGIN":"http://localhost:3000",
            "SQUIDRA_DB_PORT":"5432","SQUIDRA_DB_USER":"squidra","SQUIDRA_DB_PASSWORD":String(repeating:"fixture",count:8),"SQUIDRA_DB_NAME":"squidra"])
        let reads = try WorldReadRoutes(actorID:fixture.actor,world:fixture.world,changes:fixture.world)
        return ServerComposition.application(configuration:configuration,readiness:{ .ready },worldReads:reads)
    }
    private static func location(_ fields: [String:Any] = [:]) throws -> String {
        var input: [String:Any] = ["schemaVersion":"1","entityId":HTTPWorldFixture.entity.uuidString,"validAt":"1970-01-01T00:08:20Z","knownAt":"1970-01-01T00:08:20Z"]
        input.merge(fields) { _,new in new }; return String(decoding:try JSONSerialization.data(withJSONObject:input),as:UTF8.self)
    }
    private static func changes(cursor: String? = nil) throws -> String {
        var input: [String:Any] = ["schemaVersion":"1","subjectId":HTTPWorldFixture.entity.uuidString,"from":"1970-01-01T00:00:00Z",
            "to":"1970-01-01T00:10:00Z","knownAt":"1970-01-01T00:08:20Z","limit":1]
        if let cursor { input["cursor"] = cursor }
        return String(decoding:try JSONSerialization.data(withJSONObject:input),as:UTF8.self)
    }
    func testAuthenticationOriginAndActorRejectBeforeWorldAccess() async throws {
        let fixture = Fixture()
        try await Self.app(fixture).test(.router) { client in
            for path in ["/api/v1/world/location","/api/v1/world/changes"] {
                try await client.execute(uri:path,method:.post,body:.init(string:Self.location())) { XCTAssertEqual($0.status,.unauthorized) }
            }
            var foreign = fixture.headers; foreign[.init("X-Actor-ID")!] = UUID().uuidString
            try await client.execute(uri:"/api/v1/world/location",method:.post,headers:foreign,body:.init(string:Self.location())) { XCTAssertEqual($0.status,.forbidden) }
            var origin = fixture.headers; origin[.origin] = "https://evil.example"
            try await client.execute(uri:"/api/v1/world/location",method:.post,headers:origin,body:.init(string:Self.location())) { XCTAssertEqual($0.status,.forbidden) }
        }
        let count = await fixture.world.calls; XCTAssertEqual(count,0)
    }
    func testLiveHTTPRetainsAllConflictEvidenceAndHostRequestIdentity() async throws {
        let fixture = Fixture(.conflict), spoofed = UUID().uuidString
        try await Self.app(fixture).test(.live) { client in
            var headers = fixture.headers; headers[.origin] = "http://localhost:3000"; headers[.init("X-Request-ID")!] = spoofed
            try await client.execute(uri:"/api/v1/world/location",method:.post,headers:headers,body:.init(string:Self.location())) { response in
                XCTAssertEqual(response.status,.ok); XCTAssertEqual(response.headers[.cacheControl],"no-store")
                XCTAssertEqual(response.headers[.accessControlAllowOrigin],"http://localhost:3000")
                let id = try XCTUnwrap(response.headers[.init("X-Request-ID")!]); XCTAssertNotEqual(id,spoofed); XCTAssertNotNil(UUID(uuidString:id))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(response.body.readableBytesView)) as? [String:Any])
                XCTAssertEqual(object["actorId"] as? String,fixture.actor.uuidString.lowercased())
                let facts = try XCTUnwrap(object["facts"] as? [[String:Any]])
                XCTAssertEqual(facts.count,2); XCTAssertEqual(facts.first?["confidence"] as? Double,0.8)
                XCTAssertEqual(facts.first?["timeZone"] as? String,"Europe/Paris")
                XCTAssertTrue(facts.first?["occurredAt"] is NSNull)
                XCTAssertEqual(Set(object["uncertainty"] as? [String] ?? []),["conflictingLocations","inferredEvidence","projectionBehind"])
            }
        }
        let actor = await fixture.world.lastActor; XCTAssertEqual(actor,fixture.actor)
    }
    func testChangesContinuationRoundTripsThroughHTTPGateway() async throws {
        let fixture = Fixture()
        try await Self.app(fixture).test(.router) { client in
            let cursor = try await client.execute(uri:"/api/v1/world/changes",method:.post,headers:fixture.headers,body:.init(string:Self.changes())) { response -> String in
                XCTAssertEqual(response.status,.ok)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(response.body.readableBytesView)) as? [String:Any])
                XCTAssertEqual((object["facts"] as? [Any])?.count,2)
                return try XCTUnwrap(object["next"] as? String)
            }
            try await client.execute(uri:"/api/v1/world/changes",method:.post,headers:fixture.headers,body:.init(string:Self.changes(cursor:cursor))) { response in
                XCTAssertEqual(response.status,.ok)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(response.body.readableBytesView)) as? [String:Any])
                XCTAssertTrue(object["next"] is NSNull)
                XCTAssertEqual((object["changes"] as? [[String:Any]])?.first?["id"] as? String,HTTPWorldFixture.id(5).uuidString.lowercased())
            }
        }
        let count = await fixture.world.calls; XCTAssertEqual(count,2)
    }
    func testClosedVersionedArgumentsAndSemanticCursorErrorsReturn400() async throws {
        let fixture = Fixture()
        try await Self.app(fixture).test(.router) { client in
            for fields: [String:Any] in [["actorId":UUID().uuidString],["scope":["world:write"]],["schemaVersion":"2"],
                ["validAt":"2026-02-30T00:00:00Z"],["knownAt":"1970-01-01T00:08:20-00:00"],["entityId":"invented"]] {
                try await client.execute(uri:"/api/v1/world/location",method:.post,headers:fixture.headers,body:.init(string:Self.location(fields))) { XCTAssertEqual($0.status,.badRequest) }
            }
            try await client.execute(uri:"/api/v1/world/changes",method:.post,headers:fixture.headers,body:.init(string:Self.changes(cursor:"not-base64"))) { XCTAssertEqual($0.status,.badRequest) }
            let duplicated = #"{"schemaVersion":"1","entityId":"00000000-0000-0000-0000-000000000001","\u0065ntityId":"00000000-0000-0000-0000-000000000001"}"#
            try await client.execute(uri:"/api/v1/world/location",method:.post,headers:fixture.headers,body:.init(string:duplicated)) { XCTAssertEqual($0.status,.badRequest) }
        }
        let count = await fixture.world.calls; XCTAssertEqual(count,0)
    }
    func testAuthoritativeFutureWatermarkRejectionIsAStatic400() async throws {
        let fixture = Fixture()
        try await Self.app(fixture).test(.router) { client in
            let cursor = try await client.execute(uri:"/api/v1/world/changes",method:.post,headers:fixture.headers,body:.init(string:Self.changes())) { response -> String in
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(response.body.readableBytesView)) as? [String:Any])
                return try XCTUnwrap(object["next"] as? String)
            }
            let bytes = try XCTUnwrap(Data(base64Encoded:cursor))
            var forged = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
            forged["throughSequence"] = 1000; forged["availableThroughSequence"] = 1000
            let future = try JSONSerialization.data(withJSONObject:forged).base64EncodedString()
            try await client.execute(uri:"/api/v1/world/changes",method:.post,headers:fixture.headers,body:.init(string:Self.changes(cursor:future))) { response in
                XCTAssertEqual(response.status,.badRequest)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(response.body.readableBytesView)) as? [String:Any])
                XCTAssertEqual(object["code"] as? String,"VALIDATION_FAILED")
            }
        }
        let count = await fixture.world.calls; XCTAssertEqual(count,2)
    }
    func testMediaTypeDuplicatesAndOversizedBodiesRejectBeforeRead() async throws {
        let fixture = Fixture()
        try await Self.app(fixture).test(.router) { client in
            var headers = fixture.headers; headers[.contentType] = "text/plain"
            try await client.execute(uri:"/api/v1/world/location",method:.post,headers:headers,body:.init(string:Self.location())) { XCTAssertEqual($0.status,.badRequest) }
            headers = fixture.headers; headers.append(.init(name:.contentType,value:"application/json"))
            try await client.execute(uri:"/api/v1/world/location",method:.post,headers:headers,body:.init(string:Self.location())) { XCTAssertEqual($0.status,.badRequest) }
            for path in ["/api/v1/world/location","/api/v1/world/changes"] {
                try await client.execute(uri:path,method:.post,headers:fixture.headers,body:.init(repeating:65,count:8192)) { XCTAssertEqual($0.status,.contentTooLarge) }
            }
        }
        let count = await fixture.world.calls; XCTAssertEqual(count,0)
    }
    func testMissingEntityIsExplicitAndDoesNotInventWatermarks() async throws {
        let fixture = Fixture(.absent)
        try await Self.app(fixture).test(.router) { client in
            try await client.execute(uri:"/api/v1/world/location",method:.post,headers:fixture.headers,body:.init(string:Self.location())) { response in
                XCTAssertEqual(response.status,.ok)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(response.body.readableBytesView)) as? [String:Any])
                XCTAssertEqual(object["status"] as? String,"not_found"); XCTAssertEqual((object["facts"] as? [Any])?.count,0)
                XCTAssertTrue(object["projectedThroughSequence"] is NSNull)
            }
        }
    }
    func testPrivateCorruptAndTimedOutBackendsReturnStaticErrors() async throws {
        for mode in [HTTPWorldFixture.Mode.privateFailure,.foreignOutput,.timeout] {
            let fixture = Fixture(mode)
            try await Self.app(fixture).test(.router) { client in
                try await client.execute(uri:"/api/v1/world/location",method:.post,headers:fixture.headers,body:.init(string:Self.location())) { response in
                    XCTAssertEqual(response.status,mode == .timeout ? .gatewayTimeout : .serviceUnavailable)
                    XCTAssertEqual(response.headers[.cacheControl],"no-store")
                    let text = String(buffer:response.body)
                    XCTAssertFalse(text.contains("password")); XCTAssertFalse(text.contains("SELECT")); XCTAssertFalse(text.contains("private-db-secret"))
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(response.body.readableBytesView)) as? [String:Any])
                    XCTAssertEqual(Set(object.keys),["schemaVersion","code","message","requestId"])
                }
            }
        }
    }
    func testMisboundCompositionCannotSubstituteAuthenticatedActor() async throws {
        let fixture = Fixture()
        try await Self.app(fixture,boundaryActor:UUID()).test(.router) { client in
            try await client.execute(uri:"/api/v1/world/location",method:.post,headers:fixture.headers,body:.init(string:Self.location())) { XCTAssertEqual($0.status,.forbidden) }
        }
        let count = await fixture.world.calls; XCTAssertEqual(count,0)
    }
}
