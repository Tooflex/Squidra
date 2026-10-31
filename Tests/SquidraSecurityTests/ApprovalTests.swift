import Foundation
import SquidraDomain
import SquidraSecurity
import SquidraTools
import XCTest

private actor MemoryApprovals: ApprovalStore {
    private var records: [UUID:ApprovalRecord] = [:]
    private var observed: Int64?
    func observe(_ now: Int64) { observed = now }
    func request(_ binding: ApprovalBinding, nowMilliseconds: Int64, ttlMilliseconds: Int64, deadline: ContinuousClock.Instant) throws -> ApprovalRecord {
        if let old = records.values.first(where:{ $0.binding.actorID == binding.actorID && $0.binding.ledgerID == binding.ledgerID }) {
            guard old.binding == binding else { throw ApprovalError.conflict };return old
        }
        let record = try ApprovalRecord(id:UUID(),binding:binding,requestedAtMilliseconds:nowMilliseconds,expiresAtMilliseconds:nowMilliseconds+ttlMilliseconds)
        records[record.id] = record;return record
    }
    func load(actorID: UUID, id: UUID, deadline: ContinuousClock.Instant) throws -> ApprovalObservation {
        guard let record = records[id],record.binding.actorID == actorID else { throw ApprovalError.notFound }
        return ApprovalObservation(record:record,observedAtMilliseconds:observed ?? record.requestedAtMilliseconds)
    }
    func resolve(_ record: ApprovalRecord, response: ApprovalResponse, approverID: UUID, nowMilliseconds: Int64, deadline: ContinuousClock.Instant) throws -> ApprovalRecord {
        guard let current = records[record.id], current.binding == record.binding else { throw ApprovalError.notFound }
        if current.decision != .pending {
            guard current.decision == response.decision,current.approverID == approverID else { throw ApprovalError.conflict };return current
        }
        guard current.version == record.version else { throw ApprovalError.conflict }
        let now = max(nowMilliseconds,observed ?? nowMilliseconds)
        let decision = now >= current.expiresAtMilliseconds ? ApprovalDecision.expired : response.decision
        let next = try ApprovalRecord(id:current.id,binding:current.binding,requestedAtMilliseconds:current.requestedAtMilliseconds,
            expiresAtMilliseconds:current.expiresAtMilliseconds,decision:decision,approverID:decision == .expired ? nil : approverID,
            decidedAtMilliseconds:now,version:current.version+1)
        records[next.id] = next;return next
    }
}
private actor RevocableIdentity: ApprovalIdentityPolicy {
    private var enabled = true
    func revoke() { enabled = false }
    func mayResolve(actorID: UUID, principalID: UUID) -> Bool { enabled && actorID == principalID }
}
private struct SlowIdentity: ApprovalIdentityPolicy {
    func mayResolve(actorID: UUID, principalID: UUID) async throws -> Bool {
        try await Task.sleep(for:.seconds(2));return true
    }
}
private struct BrokenIdentity: ApprovalIdentityPolicy {
    struct PrivateFailure: Error {}
    func mayResolve(actorID: UUID, principalID: UUID) throws -> Bool { throw PrivateFailure() }
}

// SAFETY: no mutable suite state; stores and identity fixtures are actors.
final class ApprovalTests: XCTestCase, @unchecked Sendable {
    private static let instant: Int64 = 1_700_000_000_000
    private static func binding() throws -> ApprovalBinding {
        try ApprovalBinding(actorID:UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,
            runID:UUID(uuidString:"00000000-0000-0000-0000-000000000002")!,
            ledgerID:UUID(uuidString:"00000000-0000-0000-0000-000000000003")!,commandHash:Data(repeating:1,count:32))
    }
    private static func service(_ store: MemoryApprovals, now: Int64 = ApprovalTests.instant,
                                identity: any ApprovalIdentityPolicy = OwnerApprovalIdentityPolicy()) throws -> ApprovalCoordinator {
        try ApprovalCoordinator(store:store,clock:FixedClock(instant:UTCInstant(secondsSince1970:Double(now)/1_000),timeZone:IANATimeZone(identifier:"Etc/UTC")),identities:identity)
    }
    private static func approve(_ service: ApprovalCoordinator, record: ApprovalRecord) async throws -> ApprovalRecord {
        try await service.resolve(actorID:record.binding.actorID,id:record.id,response:.approve,principalID:record.binding.actorID,
            expectedDigest:record.digest,deadline:.now.advanced(by:.seconds(1)))
    }
    func testFrozenDigestBindsEveryFieldAndExactExpiry() throws {
        let binding = try Self.binding(),expiry = Self.instant+600_000
        XCTAssertEqual(binding.digest(expiresAtMilliseconds:expiry).map{String(format:"%02x",$0)}.joined(),"6dc8de5429c355cb368c43bcc93fda2c2a35af105ed73af454b1f8eb8fe967ad")
        let changed = try [ApprovalBinding(actorID:UUID(),runID:binding.runID,ledgerID:binding.ledgerID,commandHash:binding.commandHash),
            ApprovalBinding(actorID:binding.actorID,runID:UUID(),ledgerID:binding.ledgerID,commandHash:binding.commandHash),
            ApprovalBinding(actorID:binding.actorID,runID:binding.runID,ledgerID:UUID(),commandHash:binding.commandHash),
            ApprovalBinding(actorID:binding.actorID,runID:binding.runID,ledgerID:binding.ledgerID,commandHash:Data(repeating:2,count:32))]
        for value in changed { XCTAssertNotEqual(value.digest(expiresAtMilliseconds:expiry),binding.digest(expiresAtMilliseconds:expiry)) }
        XCTAssertNotEqual(binding.digest(expiresAtMilliseconds:expiry+1),binding.digest(expiresAtMilliseconds:expiry))
    }
    func testRequestReplayDoesNotExtendTenMinuteTTL() async throws {
        let store = MemoryApprovals(),binding = try Self.binding()
        let first = try await Self.service(store).request(binding,deadline:.now.advanced(by:.seconds(1)))
        let replay = try await Self.service(store,now:Self.instant+500_000).request(binding,deadline:.now.advanced(by:.seconds(1)))
        XCTAssertEqual(first,replay);XCTAssertEqual(first.expiresAtMilliseconds-first.requestedAtMilliseconds,600_000)
        for ttl: Int64 in [0,600_001,Int64.max] {
            do { _ = try await Self.service(store).request(binding,ttlMilliseconds:ttl,deadline:.now.advanced(by:.seconds(1)));XCTFail("Invalid TTL accepted") }
            catch { XCTAssertEqual(error as? ApprovalError,.invalidRequest) }
        }
    }
    func testPendingCannotAuthorizeAndApprovalSurvivesCoordinatorRestart() async throws {
        let store = MemoryApprovals(),service = try Self.service(store),binding = try Self.binding()
        let pending = try await service.request(binding,deadline:.now.advanced(by:.seconds(1)))
        do { _ = try await service.verify(actorID:binding.actorID,id:pending.id,binding:binding,deadline:.now.advanced(by:.seconds(1)));XCTFail("Pending authorized") }
        catch { XCTAssertEqual(error as? ApprovalError,.notApproved) }
        let approved = try await Self.approve(service,record:pending)
        let restarted = try Self.service(store,now:Self.instant+1)
        let reloaded = try await restarted.load(actorID:binding.actorID,id:approved.id,deadline:.now.advanced(by:.seconds(1)))
        XCTAssertEqual(approved,reloaded)
        let proof = try await restarted.verify(actorID:binding.actorID,id:approved.id,binding:binding,deadline:.now.advanced(by:.seconds(1)))
        XCTAssertEqual(proof.binding,binding);XCTAssertEqual(proof.digest,approved.digest)
    }
    func testTTLExpiresAtExactBoundaryAndCannotBeApprovedAfterwards() async throws {
        let store = MemoryApprovals(),binding = try Self.binding()
        let pending = try await Self.service(store).request(binding,deadline:.now.advanced(by:.seconds(1)))
        let approved = try await Self.approve(Self.service(store),record:pending)
        _ = try await Self.service(store,now:approved.expiresAtMilliseconds-1).verify(actorID:binding.actorID,id:approved.id,binding:binding,deadline:.now.advanced(by:.seconds(1)))
        do { _ = try await Self.service(store,now:approved.expiresAtMilliseconds).verify(actorID:binding.actorID,id:approved.id,binding:binding,deadline:.now.advanced(by:.seconds(1)));XCTFail("Expired approval authorized") }
        catch { XCTAssertEqual(error as? ApprovalError,.expired) }
        let another = MemoryApprovals(),late = try await Self.service(another).request(binding,deadline:.now.advanced(by:.seconds(1)))
        let expired = try await Self.approve(Self.service(another,now:late.expiresAtMilliseconds),record:late)
        XCTAssertEqual(expired.decision,.expired);XCTAssertNil(expired.approverID)
    }
    func testWrongApproverIdentityAndIdentityErrorsFailClosed() async throws {
        let store = MemoryApprovals(),service = try Self.service(store),binding = try Self.binding()
        let pending = try await service.request(binding,deadline:.now.advanced(by:.seconds(1)))
        do { _ = try await service.resolve(actorID:binding.actorID,id:pending.id,response:.approve,principalID:UUID(),expectedDigest:pending.digest,deadline:.now.advanced(by:.seconds(1)));XCTFail("Wrong principal authorized") }
        catch { XCTAssertEqual(error as? ApprovalError,.denied) }
        do { _ = try await Self.approve(Self.service(store,identity:BrokenIdentity()),record:pending);XCTFail("Identity error authorized") }
        catch { XCTAssertEqual(error as? ApprovalError,.denied) }
        let current = try await service.load(actorID:binding.actorID,id:pending.id,deadline:.now.advanced(by:.seconds(1)));XCTAssertEqual(current.decision,.pending)
    }
    func testChangedDigestOrCommandCannotUseApproval() async throws {
        let store = MemoryApprovals(),service = try Self.service(store),binding = try Self.binding()
        let pending = try await service.request(binding,deadline:.now.advanced(by:.seconds(1)))
        do { _ = try await service.resolve(actorID:binding.actorID,id:pending.id,response:.approve,principalID:binding.actorID,expectedDigest:Data(repeating:0,count:32),deadline:.now.advanced(by:.seconds(1)));XCTFail("Tampered digest accepted") }
        catch { XCTAssertEqual(error as? ApprovalError,.conflict) }
        _ = try await Self.approve(service,record:pending)
        let changed = try ApprovalBinding(actorID:binding.actorID,runID:binding.runID,ledgerID:binding.ledgerID,commandHash:Data(repeating:9,count:32))
        do { _ = try await service.verify(actorID:binding.actorID,id:pending.id,binding:changed,deadline:.now.advanced(by:.seconds(1)));XCTFail("Changed command approved") }
        catch { XCTAssertEqual(error as? ApprovalError,.conflict) }
        do { _ = try await service.load(actorID:UUID(),id:pending.id,deadline:.now.advanced(by:.seconds(1)));XCTFail("Cross-actor read") }
        catch { XCTAssertEqual(error as? ApprovalError,.notFound) }
    }
    func testDecisionReplayIsImmutableAndOppositeDecisionConflicts() async throws {
        let store = MemoryApprovals(),service = try Self.service(store),binding = try Self.binding()
        let pending = try await service.request(binding,deadline:.now.advanced(by:.seconds(1))),first = try await Self.approve(service,record:pending)
        let replay = try await Self.approve(service,record:pending)
        XCTAssertEqual(first,replay);XCTAssertEqual(first.version,2)
        do { _ = try await service.resolve(actorID:binding.actorID,id:pending.id,response:.deny,principalID:binding.actorID,expectedDigest:pending.digest,deadline:.now.advanced(by:.seconds(1)));XCTFail("Final decision changed") }
        catch { XCTAssertEqual(error as? ApprovalError,.conflict) }
    }
    func testRevokedIdentityAndStorageObservedExpiryInvalidateProof() async throws {
        let store = MemoryApprovals(),identity = RevocableIdentity(),service = try Self.service(store,identity:identity),binding = try Self.binding()
        let pending = try await service.request(binding,deadline:.now.advanced(by:.seconds(1)))
        _ = try await Self.approve(service,record:pending);await identity.revoke()
        do { _ = try await service.verify(actorID:binding.actorID,id:pending.id,binding:binding,deadline:.now.advanced(by:.seconds(1)));XCTFail("Revoked approver authorized") }
        catch { XCTAssertEqual(error as? ApprovalError,.denied) }
        await store.observe(pending.expiresAtMilliseconds)
        do { _ = try await Self.service(store).verify(actorID:binding.actorID,id:pending.id,binding:binding,deadline:.now.advanced(by:.seconds(1)));XCTFail("Storage expiry ignored") }
        catch { XCTAssertEqual(error as? ApprovalError,.expired) }
    }
    func testSlowIdentityIsBoundedAndCancellationDoesNotResolve() async throws {
        let store = MemoryApprovals(),service = try Self.service(store,identity:SlowIdentity()),binding = try Self.binding()
        let pending = try await service.request(binding,deadline:.now.advanced(by:.seconds(1)))
        do { _ = try await service.resolve(actorID:binding.actorID,id:pending.id,response:.approve,principalID:binding.actorID,expectedDigest:pending.digest,deadline:.now.advanced(by:.milliseconds(30)));XCTFail("Slow identity authorized") }
        catch { XCTAssertEqual(error as? ApprovalError,.denied) }
        let task = Task { try await Self.approve(service,record:pending) };task.cancel()
        do { _ = try await task.value;XCTFail("Cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        let current = try await Self.service(store).load(actorID:binding.actorID,id:pending.id,deadline:.now.advanced(by:.seconds(1)))
        XCTAssertEqual(current.decision,.pending)
    }
    func testMalformedRecordsAndExpiredOperationDeadlineAreRejected() async throws {
        let binding = try Self.binding()
        XCTAssertThrowsError(try ApprovalBinding(actorID:UUID(),runID:UUID(),ledgerID:UUID(),commandHash:Data()))
        XCTAssertThrowsError(try ApprovalRecord(id:UUID(),binding:binding,requestedAtMilliseconds:Self.instant,expiresAtMilliseconds:Self.instant+600_001))
        XCTAssertThrowsError(try ApprovalRecord(id:UUID(),binding:binding,requestedAtMilliseconds:Int64.min,expiresAtMilliseconds:Int64.max))
        XCTAssertThrowsError(try ApprovalRecord(id:UUID(),binding:binding,requestedAtMilliseconds:Self.instant,expiresAtMilliseconds:Self.instant+600_000,decision:.approved,approverID:binding.actorID,decidedAtMilliseconds:Self.instant+600_000))
        do { _ = try await Self.service(MemoryApprovals()).request(binding,deadline:.now.advanced(by:.seconds(-1)));XCTFail("Expired deadline accepted") }
        catch { XCTAssertEqual(error as? ApprovalError,.unavailable) }
    }
}

private actor ApprovalLedgerFixture: ActionLedgerStore {
    private var records: [UUID:ActionRecord] = [:]
    func reserve(_ command: ActionCommand, deadline: ContinuousClock.Instant) throws -> ActionReservation {
        if let record = records.values.first(where:{$0.command.actorID == command.actorID && $0.command.tool.qualifiedName == command.tool.qualifiedName && $0.command.idempotencyKey == command.idempotencyKey}) {
            guard record.command.fingerprint == command.fingerprint else { throw ActionLedgerError.conflict };return .init(record:record,created:false)
        }
        let record = try ActionRecord(id:UUID(),command:command,status:.reserved,version:1,result:nil,providerReference:nil)
        records[record.id] = record;return .init(record:record,created:true)
    }
    func load(actorID: UUID, id: UUID, deadline: ContinuousClock.Instant) throws -> ActionRecord {
        guard let record = records[id],record.command.actorID == actorID else { throw ActionLedgerError.notFound };return record
    }
    func update(_ record: ActionRecord, to status: ActionStatus, result: ActionResult?, providerReference: String?, deadline: ContinuousClock.Instant) throws -> ActionRecord {
        guard let current = records[record.id],current.version == record.version else { throw ActionLedgerError.versionConflict }
        guard !current.status.isFinal else { throw ActionLedgerError.versionConflict }
        let next = try ActionRecord(id:record.id,command:record.command,status:status,version:record.version+1,result:result,providerReference:providerReference)
        records[record.id] = next;return next
    }
}
private actor ApprovalExecutorFixture: ToolExecutor {
    private(set) var calls = 0
    func execute(_ call: ToolCall) -> Data {
        calls += 1
        return Data(#"{"schemaVersion":"1","entityId":"00000000-0000-0000-0000-000000000001","message":"fixture effect committed"}"#.utf8)
    }
}
// SAFETY: all mutable state is protected by NSLock, including synchronous now().
private final class ApprovalClockFixture: SquidraDomain.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds: Int64 = 1_700_000_000_000
    func set(_ value: Int64) { lock.withLock { milliseconds = value } }
    func now() throws -> UTCInstant { try lock.withLock { try UTCInstant(secondsSince1970:Double(milliseconds)/1_000) } }
    func timezone() -> IANATimeZone { try! IANATimeZone(identifier:"Etc/UTC") }
    func monotonicElapsed() -> Duration { .zero }
}
private actor ApprovalPolicyFixture: PolicyEngine {
    let clock: ApprovalClockFixture
    private var enabled = true
    private var expiry: Int64?
    private var count = 0
    init(clock: ApprovalClockFixture) { self.clock = clock }
    func revoke() { enabled = false }
    func expireOnRecheck(_ value: Int64) { expiry = value;count = 0 }
    func evaluate(_ context: ActionPolicyContext) -> ActionPolicyDecision {
        guard enabled else { return .deny }
        count += 1
        if count == 2,let expiry { clock.set(expiry) }
        return .requiresApproval
    }
}

// SAFETY: stateless suite; mutable fixtures are actors or lock-protected clocks.
final class ApprovalGatewayTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        let gateway: ActionGateway, service: ApprovalCoordinator, action: GatewayAction
        let executor: ApprovalExecutorFixture, ledger: ApprovalLedgerFixture
        let clock: ApprovalClockFixture, policy: ApprovalPolicyFixture
    }
    private static func fixture(_ risk: ToolRisk = .r2) throws -> Fixture {
        let clock = ApprovalClockFixture(),policy = ApprovalPolicyFixture(clock:clock),executor = ApprovalExecutorFixture(),ledger = ApprovalLedgerFixture()
        let service = ApprovalCoordinator(store:MemoryApprovals(),clock:clock)
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let definition = try ToolDefinition(id:ToolID(namespace:"fixture",name:"echo",version:"1.0.0"),capability:"fixture.write",risk:risk,idempotency:.durableLedger,
            inputSchema:Data(contentsOf:root.appendingPathComponent("Schemas/tools/fixture.echo.1.0.0.input.json")),outputSchema:Data(contentsOf:root.appendingPathComponent("Schemas/tools/fixture.echo.1.0.0.output.json")))
        let gateway = try ActionGateway(tools:[GatewayToolRegistration(definition:definition,surface:.bounded,executor:executor,resolveTarget:{ data in
            guard let json = try JSONSerialization.jsonObject(with:data) as? [String:Any],let id = json["entityId"] as? String else { throw ApprovalError.invalidRequest };return "entity:"+id
        })],policy:policy,ledger:ActionLedger(store:ledger),approvals:service)
        let args = Data(#"{"schemaVersion":"1","entityId":"00000000-0000-0000-0000-000000000001","at":"2026-10-31T12:00:00Z","message":"fixture","limit":1}"#.utf8)
        let action = GatewayAction(actorID:UUID(),runID:UUID(),tool:definition.id,target:"entity:00000000-0000-0000-0000-000000000001",arguments:args,scope:["fixture:write"],idempotencyKey:"sensitive-key",deadline:.now.advanced(by:.seconds(3)))
        return Fixture(gateway:gateway,service:service,action:action,executor:executor,ledger:ledger,clock:clock,policy:policy)
    }
    private static func approvedAction(_ action: GatewayAction, id: UUID, runID: UUID? = nil, arguments: Data? = nil, target: String? = nil) -> GatewayAction {
        GatewayAction(actorID:action.actorID,runID:runID ?? action.runID,tool:action.tool,target:target ?? action.target,arguments:arguments ?? action.arguments,
            scope:action.scope,idempotencyKey:action.idempotencyKey,deadline:.now.advanced(by:.seconds(3)),approvalID:id)
    }
    private static func approve(_ fixture: Fixture) async throws -> ApprovalRecord {
        let pending = try await fixture.gateway.requestApproval(fixture.action)
        return try await fixture.service.resolve(actorID:fixture.action.actorID,id:pending.id,response:.approve,principalID:fixture.action.actorID,
            expectedDigest:pending.digest,deadline:.now.advanced(by:.seconds(2)))
    }
    func testRequestReturnsWithoutDispatchAndPendingNeverExecutes() async throws {
        let fixture = try Self.fixture(),pending = try await fixture.gateway.requestApproval(fixture.action)
        let count = await fixture.executor.calls;XCTAssertEqual(count,0)
        let record = try await fixture.ledger.load(actorID:fixture.action.actorID,id:pending.binding.ledgerID,deadline:.now.advanced(by:.seconds(1)))
        XCTAssertEqual(record.status,.reserved)
        do { _ = try await fixture.gateway.invoke(Self.approvedAction(fixture.action,id:pending.id));XCTFail("Pending executed") }
        catch { XCTAssertEqual(error as? ApprovalError,.notApproved) }
        let after = await fixture.executor.calls;XCTAssertEqual(after,0)
    }
    func testR2AndR3RequireApprovalAndReplayOneUntrustedEffect() async throws {
        for risk in [ToolRisk.r2,.r3] {
            let fixture = try Self.fixture(risk)
            do { _ = try await fixture.gateway.invoke(fixture.action);XCTFail("Missing approval executed") }
            catch { XCTAssertEqual(error as? ActionGatewayError,.approvalRequired) }
            let approved = try await Self.approve(fixture),action = Self.approvedAction(fixture.action,id:approved.id)
            guard case .completed(let result) = try await fixture.gateway.invoke(action) else { return XCTFail("Approved effect missing") }
            XCTAssertEqual(result.trust,.untrusted)
            guard case .replay(let replay) = try await fixture.gateway.invoke(action) else { return XCTFail("Approved result not replayed") }
            XCTAssertEqual(replay.result?.payload,result.payload)
            let count = await fixture.executor.calls;XCTAssertEqual(count,1)
        }
    }
    func testConcurrentApprovedCallsClaimOnlyOneEffect() async throws {
        let fixture = try Self.fixture(),approved = try await Self.approve(fixture),action = Self.approvedAction(fixture.action,id:approved.id)
        async let a = fixture.gateway.invoke(action)
        async let b = fixture.gateway.invoke(action)
        let results = try await [a,b]
        let completed = results.filter { if case .completed = $0 { return true };return false }
        XCTAssertEqual(completed.count,1)
        let count = await fixture.executor.calls;XCTAssertEqual(count,1)
    }
    func testChangedArgumentsAndRunCannotBorrowApproval() async throws {
        let fixture = try Self.fixture(),approved = try await Self.approve(fixture)
        let changed = Data(String(decoding:fixture.action.arguments,as:UTF8.self).replacingOccurrences(of:"fixture\"",with:"changed\"").utf8)
        do { _ = try await fixture.gateway.invoke(Self.approvedAction(fixture.action,id:approved.id,arguments:changed));XCTFail("Changed arguments executed") }
        catch { XCTAssertEqual(error as? ActionLedgerError,.conflict) }
        do { _ = try await fixture.gateway.invoke(Self.approvedAction(fixture.action,id:approved.id,runID:UUID()));XCTFail("Other run borrowed approval") }
        catch { XCTAssertEqual(error as? ApprovalError,.conflict) }
        let count = await fixture.executor.calls;XCTAssertEqual(count,0)
    }
    func testExpiredApprovalAndRevokedPolicyNeverExecute() async throws {
        let fixture = try Self.fixture(),approved = try await Self.approve(fixture)
        fixture.clock.set(approved.expiresAtMilliseconds)
        do { _ = try await fixture.gateway.invoke(Self.approvedAction(fixture.action,id:approved.id));XCTFail("Expired approval executed") }
        catch { XCTAssertEqual(error as? ApprovalError,.expired) }
        let other = try Self.fixture(),allowed = try await Self.approve(other)
        await other.policy.revoke()
        do { _ = try await other.gateway.invoke(Self.approvedAction(other.action,id:allowed.id));XCTFail("Revoked policy executed") }
        catch { XCTAssertEqual(error as? ActionGatewayError,.denied) }
        let count = await fixture.executor.calls,otherCount = await other.executor.calls
        XCTAssertEqual(count,0);XCTAssertEqual(otherCount,0)
    }
    func testExpiryAfterClaimIsRecheckedInsideDispatcherBeforeEffect() async throws {
        let fixture = try Self.fixture(),approved = try await Self.approve(fixture)
        await fixture.policy.expireOnRecheck(approved.expiresAtMilliseconds)
        do { _ = try await fixture.gateway.invoke(Self.approvedAction(fixture.action,id:approved.id));XCTFail("Approval expired before effect") }
        catch { XCTAssertEqual(error as? ApprovalError,.expired) }
        let count = await fixture.executor.calls;XCTAssertEqual(count,0)
        let record = try await fixture.ledger.load(actorID:fixture.action.actorID,id:approved.binding.ledgerID,deadline:.now.advanced(by:.seconds(1)))
        XCTAssertEqual(record.result?.failure,.notApplied)
    }
    func testR4ExtraControlsCannotBeEnabledByApprovalID() async throws {
        let fixture = try Self.fixture(.r4)
        do { _ = try await fixture.gateway.requestApproval(fixture.action);XCTFail("R4 enabled") }
        catch { XCTAssertEqual(error as? ActionGatewayError,.denied) }
        do { _ = try await fixture.gateway.invoke(Self.approvedAction(fixture.action,id:UUID()));XCTFail("R4 executed") }
        catch { XCTAssertEqual(error as? ActionGatewayError,.approvalRequired) }
        let count = await fixture.executor.calls;XCTAssertEqual(count,0)
    }
}
