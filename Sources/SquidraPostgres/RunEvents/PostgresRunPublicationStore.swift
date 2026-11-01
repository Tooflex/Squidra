import Foundation
import PostgresNIO
import SquidraAgentRuntime
import SquidraDomain
import SquidraProtocols

public struct PostgresRunPublicationStore: RunPublicationStore {
    private let events: PostgresRunEventStore
    public init(client: PostgresClient, actorID: UUID) { events = PostgresRunEventStore(client:client,actorID:actorID) }
    private struct Claim: RunPublicationClaim {
        let binding: AGUIRunBinding, executionExpiresAt: UTCInstant, owner: UUID
        var localOwnership: LocalRunOwnership? = nil
    }
    public func claim(_ binding: AGUIRunBinding, maximumExecutionSeconds: Int, at: UTCInstant, deadline: ContinuousClock.Instant) async throws -> any RunPublicationClaim {
        guard binding.actorID == events.actorID else { throw RunEventStoreError.notFound }
        guard (1...180).contains(maximumExecutionSeconds) else { throw RunEventStoreError.invalidRequest }
        let owner = UUID(),leaseSeconds = maximumExecutionSeconds+5
        return try await events.transaction(deadline) { connection in
            guard let metadata = try await events.select(connection,runID:binding.runID,write:true) else { throw RunEventStoreError.notFound }
            guard !metadata.expired else { throw RunEventStoreError.expired }
            guard metadata.info.binding == binding else { throw RunEventStoreError.conflict }
            let state = try await events.publicationMetadata(connection,runID:binding.runID)
            _ = try await events.history(connection,metadata:metadata)
            // Even the same owner cannot obtain a second successful claim.
            guard state.phase == .unmanaged,metadata.info.nextSequence == 1,!metadata.info.isTerminal else { throw RunEventStoreError.conflict }
            let rows = try await BoundedPostgresQuery.rows(connection,"""
                WITH moment AS (SELECT clock_timestamp() AS stamp)
                UPDATE run_event_streams SET publication_phase='running',execution_owner=\(owner),
                    execution_lease_until=moment.stamp+\(leaseSeconds)::bigint*interval '1 second'
                FROM moment WHERE actor_id=\(events.actorID) AND run_id=\(binding.runID)
                    AND expires_at>moment.stamp+\(leaseSeconds)::bigint*interval '1 second'
                RETURNING floor(extract(epoch FROM execution_lease_until)*1000000)::bigint
                """)
            guard rows.count == 1,let row = rows.first else { throw RunEventStoreError.expired }
            let expires = try row.decode(Int64.self)
            _ = try await events.appendLocked(connection,binding:binding,expectedNextSequence:1,
                events:[AGUIEvent.started(binding:binding,at:at)],authorization:.owner(owner),terminalPhase:nil)
            return Claim(binding:binding,executionExpiresAt:try UTCInstant(secondsSince1970:Double(expires)/1_000_000-5),owner:owner) as any RunPublicationClaim
        }
    }
    /// Transfers a registered stopped process's publication claim under the same
    /// local lock. The host must keep the handle held until all resumed workers join.
    /// Neither the original lease nor its execution deadline is extended. A lost
    /// acknowledgement is not permission to dispatch again from this process.
    public func takeOver(runID: UUID, ownership: LocalRunOwnership, deadline: ContinuousClock.Instant) async throws -> any RunPublicationClaim {
        guard ownership.actorID == events.actorID else { throw RunEventStoreError.notFound }
        guard ownership.isHeld else { throw RunEventStoreError.conflict }
        return try await events.transaction(deadline) { c in
            guard ownership.isHeld else { throw RunEventStoreError.conflict }
            guard let metadata = try await events.select(c,runID:runID,write:true) else { throw RunEventStoreError.notFound }
            guard !metadata.expired else { throw RunEventStoreError.expired }
            guard metadata.info.nextSequence == 2,!metadata.info.isTerminal else { throw RunEventStoreError.conflict }
            _ = try await events.history(c,metadata:metadata)
            let actor = ownership.actorID,domain = ownership.domainID,file = ownership.fileID,owner = ownership.ownerID
            let rows = try await BoundedPostgresQuery.rows(c,"""
                UPDATE run_event_streams s SET execution_owner=\(owner)
                FROM read_run_owners o JOIN read_run_local_domains d
                    ON d.actor_id=o.actor_id AND d.domain_id=o.domain_id AND d.file_id=o.file_id
                WHERE s.actor_id=\(actor) AND s.run_id=\(runID)
                    AND o.actor_id=s.actor_id AND o.run_id=s.run_id
                    AND o.domain_id=\(domain) AND o.file_id=\(file) AND o.owner_id<>\(owner)
                    AND s.publication_phase='running' AND s.execution_owner<>\(owner)
                    AND s.execution_lease_until>clock_timestamp()+interval '5 seconds'
                    AND s.expires_at>clock_timestamp()
                RETURNING floor(extract(epoch FROM s.execution_lease_until)*1000000)::bigint
                """)
            guard rows.count == 1,let row = rows.first else { throw RunEventStoreError.conflict }
            let expires = try row.decode(Int64.self)
            guard ownership.isHeld else { throw RunEventStoreError.conflict }
            return Claim(binding:metadata.info.binding,executionExpiresAt:try UTCInstant(secondsSince1970:Double(expires)/1_000_000-5),
                owner:owner,localOwnership:ownership) as any RunPublicationClaim
        }
    }
    public func finish(_ claim: any RunPublicationClaim, outcome: RunPublicationOutcome, at: UTCInstant, deadline: ContinuousClock.Instant) async throws -> RunPublicationStatus {
        guard let claim = claim as? Claim else { throw RunEventStoreError.invalidRequest }
        guard claim.localOwnership?.isHeld != false else { throw RunEventStoreError.conflict }
        guard claim.binding.actorID == events.actorID else { throw RunEventStoreError.notFound }
        let batch:[AGUIEvent],phase:RunPublicationPhase
        do { switch outcome {
        case .answer(let answer,let messageID):
            batch = try AGUIEvent.answer(answer,binding:claim.binding,messageID:messageID,at:at)+[AGUIEvent.finished(binding:claim.binding,at:at)]
            phase = .succeeded
        case .failed(let failure):
            batch = try [AGUIEvent.failed(binding:claim.binding,at:at,code:failure)]
            phase = failure == .recoveryRequired ? .recoveryRequired : .failed
        case .cancelled:
            batch = try [AGUIEvent.finished(binding:claim.binding,at:at,outcome:.cancelled)];phase = .cancelled
        }
        } catch { throw RunEventStoreError.invalidRequest }
        return try await events.transaction(deadline) { connection in
            guard claim.localOwnership?.isHeld != false else { throw RunEventStoreError.conflict }
            let stream = try await events.appendLocked(connection,binding:claim.binding,expectedNextSequence:2,events:batch,authorization:.owner(claim.owner),terminalPhase:phase)
            return RunPublicationStatus(phase:phase,stream:stream,leaseExpired:false)
        }
    }
    public func status(actorID: UUID, runID: UUID, deadline: ContinuousClock.Instant) async throws -> RunPublicationStatus {
        guard actorID == events.actorID else { throw RunEventStoreError.notFound }
        return try await events.transaction(deadline) { connection in
            guard let metadata = try await events.select(connection,runID:runID,write:false) else { throw RunEventStoreError.notFound }
            guard !metadata.expired else { throw RunEventStoreError.expired }
            let history = try await events.history(connection,metadata:metadata),state = try await events.publicationMetadata(connection,runID:runID)
            if state.phase == .running {
                guard !metadata.info.isTerminal,history.records.count == 1 else { throw RunEventStoreError.corruptRecord }
            } else if state.phase != .unmanaged {
                guard metadata.info.isTerminal,let last = history.records.last,
                      let object = try JSONSerialization.jsonObject(with:last.json) as? [String:Any] else { throw RunEventStoreError.corruptRecord }
                let kinds = try history.records.map { record -> String in
                    guard let fields = try JSONSerialization.jsonObject(with:record.json) as? [String:Any],let kind = fields["type"] as? String else { throw RunEventStoreError.corruptRecord }
                    return kind
                }
                let expectedKinds: [AGUIEventKind] = state.phase == .succeeded ? [.runStarted,.groundedAnswer,.textStart,.textContent,.textEnd,.runFinished] : [.runStarted,state.phase == .cancelled ? .runFinished : .runError]
                guard kinds == expectedKinds.map(\.rawValue) else { throw RunEventStoreError.corruptRecord }
                switch state.phase {
                case .succeeded,.cancelled:
                    let outcome = object["outcome"] as? [String:Any]
                    guard object["type"] as? String == AGUIEventKind.runFinished.rawValue,
                          outcome?["type"] as? String == (state.phase == .succeeded ? "success" : "cancelled") else { throw RunEventStoreError.corruptRecord }
                case .failed,.recoveryRequired:
                    let codes = state.phase == .recoveryRequired ? [AGUIPublicFailure.recoveryRequired.rawValue] : [AGUIPublicFailure.executionFailed.rawValue,AGUIPublicFailure.deadlineExceeded.rawValue]
                    guard object["type"] as? String == AGUIEventKind.runError.rawValue,let code = object["code"] as? String,codes.contains(code) else { throw RunEventStoreError.corruptRecord }
                case .unmanaged,.running: throw RunEventStoreError.corruptRecord
                }
            }
            return RunPublicationStatus(phase:state.phase,stream:metadata.info,leaseExpired:state.phase == .running && state.leaseValid == false)
        }
    }
    /// Bounded background publication only. Never starts a model/runtime/tool.
    public func recoverNextCompleted(at: UTCInstant,deadline: ContinuousClock.Instant) async throws -> Bool {
        try await events.transaction(deadline) { c in
            let rows = try await BoundedPostgresQuery.rows(c,"""
                SELECT s.run_id,s.thread_id,s.request_id FROM run_event_streams s
                JOIN agent_runs r ON r.actor_id=s.actor_id AND r.id=s.run_id
                JOIN read_run_completions a ON a.actor_id=s.actor_id AND a.run_id=s.run_id
                WHERE s.actor_id=\(events.actorID) AND s.publication_phase='running'
                    AND s.execution_lease_until<=clock_timestamp() AND s.expires_at>clock_timestamp()
                    AND r.state='COMPLETED' AND r.version>a.responding_version
                ORDER BY s.execution_lease_until,s.run_id LIMIT 1 FOR UPDATE OF s SKIP LOCKED
                """)
            guard let row = rows.first else { return false }
            let (run,thread,request) = try row.decode((UUID,UUID,UUID).self)
            let binding = AGUIRunBinding(actorID:events.actorID,runID:run,threadID:thread,requestID:request)
            guard try await events.recoverArchivedCompletion(c,binding:binding,at:at) != nil else { throw RunEventStoreError.corruptRecord }
            return true
        }
    }
    /// Publishes an already completed archive from a stopped registered process.
    /// Local ownership permits finalization before lease expiry or after the
    /// execution budget ends; this path never resumes execution or renews a lease.
    public func recoverCompleted(runID: UUID, ownership: LocalRunOwnership, at: UTCInstant, deadline: ContinuousClock.Instant) async throws -> Bool {
        guard ownership.actorID == events.actorID else { throw RunEventStoreError.notFound }
        guard ownership.isHeld else { throw RunEventStoreError.conflict }
        return try await events.transaction(deadline) { c in
            guard ownership.isHeld else { throw RunEventStoreError.conflict }
            guard let metadata = try await events.select(c,runID:runID,write:true) else { throw RunEventStoreError.notFound }
            guard !metadata.expired else { throw RunEventStoreError.expired }
            let actor = ownership.actorID,domain = ownership.domainID,file = ownership.fileID,owner = ownership.ownerID
            let registered = try await BoundedPostgresQuery.rows(c,"""
                SELECT o.owner_id FROM read_run_owners o JOIN read_run_local_domains d
                    ON d.actor_id=o.actor_id AND d.domain_id=o.domain_id AND d.file_id=o.file_id
                WHERE o.actor_id=\(actor) AND o.run_id=\(runID)
                    AND o.domain_id=\(domain) AND o.file_id=\(file) AND o.owner_id<>\(owner)
                """)
            guard registered.count == 1 else { throw RunEventStoreError.conflict }
            let state = try await events.publicationMetadata(c,runID:runID)
            guard state.phase == .running,!metadata.info.isTerminal else { return false }
            guard let publicationOwner = state.owner else { throw RunEventStoreError.corruptRecord }
            let stream = try await events.recoverArchivedCompletion(c,binding:metadata.info.binding,at:at,authorization:.stoppedOwner(publicationOwner))
            guard ownership.isHeld else { throw RunEventStoreError.conflict }
            return stream != nil
        }
    }
    public func recoverExpired(actorID: UUID, runID: UUID, at: UTCInstant, deadline: ContinuousClock.Instant) async throws -> RunPublicationStatus {
        guard actorID == events.actorID else { throw RunEventStoreError.notFound }
        return try await events.transaction(deadline) { connection in
            guard let metadata = try await events.select(connection,runID:runID,write:true) else { throw RunEventStoreError.notFound }
            guard !metadata.expired else { throw RunEventStoreError.expired }
            if let stream = try await events.recoverArchivedCompletion(connection,binding:metadata.info.binding,at:at) {
                return RunPublicationStatus(phase:.succeeded,stream:stream,leaseExpired:false)
            }
            let stream = try await events.appendLocked(connection,binding:metadata.info.binding,expectedNextSequence:2,
                events:[AGUIEvent.failed(binding:metadata.info.binding,at:at,code:.recoveryRequired)],authorization:.expiredLease,terminalPhase:.recoveryRequired)
            return RunPublicationStatus(phase:.recoveryRequired,stream:stream,leaseExpired:false)
        }
    }
}
