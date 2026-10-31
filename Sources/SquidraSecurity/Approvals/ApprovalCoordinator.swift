import Foundation
import SquidraDomain

public protocol ApprovalIdentityPolicy: Sendable {
    /// Principal must come from an authenticated host context, never request JSON.
    func mayResolve(actorID: UUID, principalID: UUID) async throws -> Bool
}
public struct OwnerApprovalIdentityPolicy: ApprovalIdentityPolicy {
    public init() {}
    public func mayResolve(actorID: UUID, principalID: UUID) -> Bool { actorID == principalID }
}
public struct ApprovalCoordinator: ApprovalAuthorizer {
    private let store: any ApprovalStore
    private let clock: any SquidraDomain.Clock
    private let identities: any ApprovalIdentityPolicy
    public init(store: any ApprovalStore, clock: any SquidraDomain.Clock, identities: any ApprovalIdentityPolicy = OwnerApprovalIdentityPolicy()) {
        self.store = store; self.clock = clock; self.identities = identities
    }
    public func request(_ binding: ApprovalBinding, ttlMilliseconds: Int64 = 600_000, deadline: ContinuousClock.Instant) async throws -> ApprovalRecord {
        try check(deadline)
        guard (1...600_000).contains(ttlMilliseconds) else { throw ApprovalError.invalidRequest }
        let record = try await store.request(binding, nowMilliseconds:now(), ttlMilliseconds:ttlMilliseconds, deadline:deadline)
        try check(deadline)
        guard record.binding == binding else { throw ApprovalError.conflict }
        return record
    }
    public func load(actorID: UUID, id: UUID, deadline: ContinuousClock.Instant) async throws -> ApprovalRecord {
        try check(deadline)
        let observation = try await store.load(actorID:actorID,id:id,deadline:deadline)
        try check(deadline)
        guard observation.record.binding.actorID == actorID, observation.record.id == id else { throw ApprovalError.notFound }
        return observation.record
    }
    public func resolve(actorID: UUID, id: UUID, response: ApprovalResponse, principalID: UUID,
                        expectedDigest: Data, deadline: ContinuousClock.Instant) async throws -> ApprovalRecord {
        try check(deadline)
        try await authorizeIdentity(actorID:actorID,principalID:principalID,deadline:deadline)
        try check(deadline)
        let record = try await load(actorID:actorID,id:id,deadline:deadline)
        guard expectedDigest.count == 32, record.digest == expectedDigest else { throw ApprovalError.conflict }
        if record.decision != .pending {
            guard record.decision == response.decision, record.approverID == principalID else { throw ApprovalError.conflict }
            return record
        }
        let decided = try await store.resolve(record,response:response,approverID:principalID,nowMilliseconds:now(),deadline:deadline)
        try check(deadline)
        return decided
    }
    public func verify(actorID: UUID, id: UUID, binding: ApprovalBinding, deadline: ContinuousClock.Instant) async throws -> VerifiedApproval {
        try check(deadline)
        let observation = try await store.load(actorID:actorID,id:id,deadline:deadline),record = observation.record
        guard record.id == id, binding.actorID == actorID, record.binding == binding,
              record.digest == binding.digest(expiresAtMilliseconds:record.expiresAtMilliseconds) else { throw ApprovalError.conflict }
        guard record.decision == .approved, let approver = record.approverID else { throw ApprovalError.notApproved }
        try await authorizeIdentity(actorID:actorID,principalID:approver,deadline:deadline)
        guard max(try now(),observation.observedAtMilliseconds) < record.expiresAtMilliseconds else { throw ApprovalError.expired }
        try check(deadline)
        return VerifiedApproval(id:id,binding:binding,digest:record.digest,expiresAtMilliseconds:record.expiresAtMilliseconds)
    }
    private func authorizeIdentity(actorID: UUID, principalID: UUID, deadline: ContinuousClock.Instant) async throws {
        do {
            let allowed = try await withThrowingTaskGroup(of:Bool.self) { group in
                group.addTask { try await identities.mayResolve(actorID:actorID,principalID:principalID) }
                group.addTask { try await Task.sleep(until:deadline);throw ApprovalError.denied }
                defer { group.cancelAll() };return try await group.next()!
            }
            try check(deadline)
            guard allowed else { throw ApprovalError.denied }
        } catch is CancellationError { throw CancellationError() }
        catch { throw ApprovalError.denied }
    }
    private func now() throws -> Int64 {
        do { return Int64((try clock.now().secondsSince1970 * 1_000).rounded(.down)) }
        catch { throw ApprovalError.unavailable }
    }
    private func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ApprovalError.unavailable }
    }
}
