import Foundation
import PostgresNIO
import SquidraDomain
import SquidraProtocols

public struct PostgresRunPublicationStore: RunPublicationStore {
    private let events: PostgresRunEventStore
    public init(client: PostgresClient, actorID: UUID) { events = PostgresRunEventStore(client:client,actorID:actorID) }
    private struct Claim: RunPublicationClaim {
        let binding: AGUIRunBinding, executionExpiresAt: UTCInstant, owner: UUID
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
    public func finish(_ claim: any RunPublicationClaim, outcome: RunPublicationOutcome, at: UTCInstant, deadline: ContinuousClock.Instant) async throws -> RunPublicationStatus {
        guard let claim = claim as? Claim else { throw RunEventStoreError.invalidRequest }
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
    public func recoverExpired(actorID: UUID, runID: UUID, at: UTCInstant, deadline: ContinuousClock.Instant) async throws -> RunPublicationStatus {
        guard actorID == events.actorID else { throw RunEventStoreError.notFound }
        return try await events.transaction(deadline) { connection in
            guard let metadata = try await events.select(connection,runID:runID,write:true) else { throw RunEventStoreError.notFound }
            guard !metadata.expired else { throw RunEventStoreError.expired }
            let stream = try await events.appendLocked(connection,binding:metadata.info.binding,expectedNextSequence:2,
                events:[AGUIEvent.failed(binding:metadata.info.binding,at:at,code:.recoveryRequired)],authorization:.expiredLease,terminalPhase:.recoveryRequired)
            return RunPublicationStatus(phase:.recoveryRequired,stream:stream,leaseExpired:false)
        }
    }
}
