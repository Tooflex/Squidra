import Foundation
import SquidraDomain
import SquidraSecurity
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
