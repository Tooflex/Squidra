import Foundation
import PostgresNIO
import SquidraAgentRuntime
import SquidraDomain
import SquidraPostgres
import SquidraSecurity
import SquidraTools

private struct ApprovalManifest: Codable {
    let stage: String
    let snapshot: RunSnapshot
    let actionID: UUID, approvalID: UUID
    let digest: Data
    let expiresAtMilliseconds: Int64
}

extension RunCrashFixture {
    static let approvalStages = ["approval_pending", "approval_approved", "approval_denied",
                                 "approval_withdrawn", "approval_expired", "approval_approved_expired"]

    static func approvalCrash(mode: String, stage: String, path: URL, client: PostgresClient,
                              clock: FixtureClock, tool: ToolID) async throws {
        let runs = PostgresRunStore(client: client), actions = PostgresActionLedger(client: client)
        let approvals = ApprovalCoordinator(store: PostgresApprovalStore(client: client), clock: clock)
        let wait = ApprovalWait(approvals: approvals, runs: runs, clock: clock)
        // Store ports accept at most five seconds per I/O. Refresh the bounded
        // deadline for each operation, independently of the approval TTL wait.
        var deadline: ContinuousClock.Instant { .now.advanced(by: .seconds(4)) }
        if mode == "seed" {
            _ = try await client.query("CREATE TABLE IF NOT EXISTS crash_receipts(action_id uuid PRIMARY KEY)").collect()
            let controller = try await RunController.create(actorID: UUID(), store: runs, clock: clock)
            _ = try await controller.transition(to: .validating)
            _ = try await controller.transition(to: .planning)
            let initial = try await controller.snapshot()
            let command = try command(actor: initial.actorID, run: initial.id, tool: tool)
            _ = try await controller.validatedProposal(semanticDigest: command.fingerprintHex, invocationKey: command.idempotencyKey)
            let action = try await actions.reserve(command, deadline: deadline).record
            let binding = try ApprovalBinding(actorID: initial.actorID, runID: initial.id,
                ledgerID: action.id, commandHash: command.fingerprint)
            let approval = try await approvals.request(binding,
                ttlMilliseconds: stage.contains("expired") ? 3000 : 600_000, deadline: deadline)
            let waiting = try await wait.suspend(controller, for: approval)
            guard waiting.state == .waitingApproval, waiting.calls == 0, waiting.deadlineSecondsSince1970 == nil else {
                throw FixtureFailure.invalid
            }
            let response: ApprovalResponse?
            switch stage {
            case "approval_approved", "approval_approved_expired": response = .approve
            case "approval_denied": response = .deny
            case "approval_withdrawn": response = .withdraw
            default: response = nil
            }
            if let response {
                _ = try await approvals.resolve(actorID: initial.actorID, id: approval.id, response: response,
                    principalID: initial.actorID, expectedDigest: approval.digest, deadline: deadline)
            }
            try JSONEncoder().encode(ApprovalManifest(stage: stage, snapshot: waiting, actionID: action.id,
                approvalID: approval.id, digest: approval.digest, expiresAtMilliseconds: approval.expiresAtMilliseconds))
                .write(to: path, options: .atomic)
            try await Task.sleep(for: .seconds(120))
            throw FixtureFailure.invalid
        }

        let manifest = try JSONDecoder().decode(ApprovalManifest.self, from: Data(contentsOf: path))
        guard manifest.stage == stage else { throw FixtureFailure.invalid }
        let original = manifest.snapshot, actor = original.actorID, run = original.id
        let command = try command(actor: actor, run: run, tool: tool)
        let record = try await approvals.load(actorID: actor, id: manifest.approvalID, deadline: deadline)
        guard record.digest == manifest.digest, record.expiresAtMilliseconds == manifest.expiresAtMilliseconds,
              record.binding.actorID == actor, record.binding.runID == run,
              record.binding.ledgerID == manifest.actionID, record.binding.commandHash == command.fingerprint else {
            throw FixtureFailure.invalid
        }
        if mode == "resume" {
            let reloaded = try await runs.load(actorID: actor, runID: run, deadline: deadline)
            guard reloaded == original else { throw FixtureFailure.invalid }
            // Real time passes while the owning process is dead; expiry remains
            // the original PostgreSQL timestamp, never a restarted TTL.
            if stage.contains("expired") {
                let remaining = manifest.expiresAtMilliseconds - Int64(Date().timeIntervalSince1970 * 1000)
                if remaining >= 0 { try await Task.sleep(for: .milliseconds(remaining + 20)) }
            }
            var result = try await wait.resume(actorID: actor, approvalID: manifest.approvalID, deadline: deadline)
            if stage == "approval_pending" {
                guard case .waiting(let current) = result, current == original else { throw FixtureFailure.invalid }
                // An explicit fixture owner decision, never inferred approval.
                _ = try await approvals.resolve(actorID: actor, id: manifest.approvalID, response: .approve,
                    principalID: actor, expectedDigest: manifest.digest, deadline: deadline)
                result = try await wait.resume(actorID: actor, approvalID: manifest.approvalID, deadline: deadline)
            }
            switch result {
            case .ready(let controller):
                guard ["approval_pending", "approval_approved"].contains(stage) else { throw FixtureFailure.invalid }
                let value = try await controller.snapshot()
                guard value.state == .validating, value.substate == .policyCheck,
                      value.activeMilliseconds == original.activeMilliseconds else { throw FixtureFailure.invalid }
            case .refused(let value):
                guard value.terminalCode == (stage == "approval_withdrawn" ? .cancelled : .policyDenied) else {
                    throw FixtureFailure.invalid
                }
            case .waiting: throw FixtureFailure.invalid
            }
        }
        let final = try await runs.load(actorID: actor, runID: run, deadline: deadline)
        let allowed = ["approval_pending", "approval_approved"].contains(stage)
        guard final.state == (allowed ? .validating : (stage == "approval_withdrawn" ? .cancelled : .failed)),
              final.traceID == original.traceID, final.budget == original.budget,
              final.steps == original.steps, final.calls == 0, final.activeMilliseconds == original.activeMilliseconds,
              final.version == original.version + 1 else { throw FixtureFailure.invalid }
        let action = try await actions.load(actorID: actor, id: manifest.actionID, deadline: deadline)
        guard action.status == .reserved, action.command.idempotencyKey == command.idempotencyKey,
              action.command.fingerprint == command.fingerprint else { throw FixtureFailure.invalid }
        let rows = try await client.query("SELECT count(*)::bigint FROM crash_receipts WHERE action_id=\(manifest.actionID)").collect()
        guard try rows[0].decode(Int64.self) == 0 else { throw FixtureFailure.repeated }
        // Both this process and a second fresh verifier must reject replaying the
        // old wait; approval restoration itself never grants a tool permit.
        do {
            _ = try await wait.resume(actorID: actor, approvalID: manifest.approvalID, deadline: deadline)
            throw FixtureFailure.repeated
        } catch RunError.recoveryRequired { guard allowed else { throw FixtureFailure.invalid } }
        catch RunError.terminal { guard !allowed else { throw FixtureFailure.invalid } }
        print("CRASH_RECOVERY_VERIFIED")
    }
}
