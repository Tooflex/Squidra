import Foundation

/// Durable-first coordinator, independent of any provider or SQL transport.
/// Gateway policy/approval and runtime budgets must run before dispatch.
public struct ActionLedger: Sendable {
    private let store: any ActionLedgerStore
    public init(store: any ActionLedgerStore) { self.store = store }

    public func prepare(_ command: ActionCommand, deadline: ContinuousClock.Instant) async throws -> ActionPreparation {
        try Task.checkCancellation()
        let reservation = try await store.reserve(command, deadline: deadline)
        guard reservation.record.command.fingerprint == command.fingerprint else { throw ActionLedgerError.conflict }
        if reservation.created, reservation.record.status == .reserved {
            do {
                let claimed = try await store.update(reservation.record, to: .pending, result: nil, providerReference: nil, deadline: deadline)
                return .dispatch(ActionDispatchPermit(record: claimed))
            } catch ActionLedgerError.versionConflict {
                return classify(try await store.load(actorID: command.actorID, id: reservation.record.id, deadline: deadline))
            }
        }
        return classify(reservation.record)
    }
    public func complete(_ permit: ActionDispatchPermit, result: ActionResult, providerReference: String? = nil,
                         deadline: ContinuousClock.Instant) async throws -> ActionRecord {
        try result.validate()
        guard result.status != .succeeded || result.toolIdentifier == permit.record.command.tool.identifier else { throw ActionLedgerError.invalidOutcome }
        do {
            return try await store.update(permit.record, to: result.status, result: result, providerReference: providerReference, deadline: deadline)
        } catch ActionLedgerError.versionConflict {
            let current = try await store.load(actorID: permit.record.command.actorID, id: permit.record.id, deadline: deadline)
            if current.status.isFinal, current.result == result { return current }
            if current.status == .unknown { throw ActionLedgerError.reconciliationRequired }
            throw ActionLedgerError.conflict
        }
    }
    public func markUnknown(_ permit: ActionDispatchPermit, providerReference: String? = nil,
                            deadline: ContinuousClock.Instant) async throws -> ActionRecord {
        do { return try await store.update(permit.record, to: .unknown, result: nil, providerReference: providerReference, deadline: deadline) }
        catch ActionLedgerError.versionConflict {
            let current = try await store.load(actorID: permit.record.command.actorID, id: permit.record.id, deadline: deadline)
            guard current.status == .unknown || current.status.isFinal else { throw ActionLedgerError.versionConflict }
            return current
        }
    }
    /// Caller supplies a provider/target-confirmed outcome, not model text or a
    /// database-status guess. This never authorizes another execution attempt.
    public func reconcile(_ record: ActionRecord, confirmed result: ActionResult,
                          providerReference: String? = nil, deadline: ContinuousClock.Instant) async throws -> ActionRecord {
        guard record.status == .unknown || record.status == .pending else { throw ActionLedgerError.reconciliationRequired }
        try result.validate()
        guard result.status != .succeeded || result.toolIdentifier == record.command.tool.identifier else { throw ActionLedgerError.invalidOutcome }
        return try await store.update(record, to: result.status, result: result, providerReference: providerReference, deadline: deadline)
    }
    private func classify(_ record: ActionRecord) -> ActionPreparation {
        if record.status.isFinal { return .replay(record) }
        if record.status == .unknown { return .reconciliationRequired(record) }
        return .inProgress(record)
    }
}
