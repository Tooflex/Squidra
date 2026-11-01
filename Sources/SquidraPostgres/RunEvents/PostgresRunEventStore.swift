import Foundation
import PostgresNIO
import SquidraDomain
import SquidraProtocols

/// Fixed actor boundary. Replay is read-only and cannot resume an agent/action.
public struct PostgresRunEventStore: RunEventStore {
    private let client: PostgresClient
    public let actorID: UUID
    public init(client: PostgresClient, actorID: UUID) { self.client = client;self.actorID = actorID }
    internal struct Metadata: Sendable { let info: AGUIRunStreamInfo;let expired: Bool }
    public func create(_ binding: AGUIRunBinding, retentionSeconds: Int, deadline: ContinuousClock.Instant) async throws -> AGUIRunStreamInfo {
        guard binding.actorID == actorID else { throw RunEventStoreError.notFound }
        guard (1...604_800).contains(retentionSeconds) else { throw RunEventStoreError.invalidRequest }
        return try await transaction(deadline) { connection in
            _ = try await BoundedPostgresQuery.rows(connection,"""
                INSERT INTO run_event_streams(run_id,actor_id,thread_id,request_id,retention_seconds,created_at,expires_at)
                SELECT \(binding.runID),\(actorID),\(binding.threadID),\(binding.requestID),\(retentionSeconds),stamp,
                    stamp+\(retentionSeconds)::bigint*interval '1 second' FROM (SELECT clock_timestamp() AS stamp) AS clock
                ON CONFLICT(run_id) DO NOTHING
                """)
            guard let metadata = try await select(connection,runID:binding.runID,write:true) else { throw RunEventStoreError.conflict }
            guard metadata.info.binding == binding,metadata.info.retentionSeconds == retentionSeconds else { throw RunEventStoreError.conflict }
            guard !metadata.expired else { throw RunEventStoreError.expired }
            _ = try await history(connection,metadata:metadata)
            return metadata.info
        }
    }
    public func append(_ binding: AGUIRunBinding, expectedNextSequence: Int64, events: [AGUIEvent], deadline: ContinuousClock.Instant) async throws -> AGUIRunStreamInfo {
        guard binding.actorID == actorID else { throw RunEventStoreError.notFound }
        guard (1...16).contains(events.count),events.allSatisfy({ $0.binding == binding }),
              events.reduce(0,{ $0+$1.json.count }) <= 262_144 else { throw RunEventStoreError.invalidRequest }
        return try await transaction(deadline) { connection in
            try await appendLocked(connection,binding:binding,expectedNextSequence:expectedNextSequence,events:events,authorization:.unmanaged,terminalPhase:nil)
        }
    }
    internal enum PublicationAuthorization: Sendable {
        case unmanaged, owner(UUID), stoppedOwner(UUID), expiredLease
        var requiresLiveLease: Bool { if case .owner = self { true } else { false } }
        var requiresExpiredLease: Bool { if case .expiredLease = self { true } else { false } }
    }
    internal func appendLocked(_ connection: PostgresConnection, binding: AGUIRunBinding, expectedNextSequence: Int64,
                               events: [AGUIEvent], authorization: PublicationAuthorization, terminalPhase: RunPublicationPhase?) async throws -> AGUIRunStreamInfo {
        guard binding.actorID == actorID,(1...16).contains(events.count),events.allSatisfy({ $0.binding == binding }),
              events.reduce(0,{ $0+$1.json.count }) <= 262_144 else { throw RunEventStoreError.invalidRequest }
        return try await appendDocumentsLocked(connection,binding:binding,expectedNextSequence:expectedNextSequence,
            documents:events.map { ($0.kind.rawValue,$0.json) },authorization:authorization,terminalPhase:terminalPhase)
    }
    // Only typed producers or the checked durable-completion path below can
    // reach this byte-level append. There is no public raw producer factory.
    private func appendDocumentsLocked(_ connection: PostgresConnection,binding: AGUIRunBinding,expectedNextSequence: Int64,
        documents: [(kind:String,json:Data)],authorization: PublicationAuthorization,terminalPhase: RunPublicationPhase?) async throws -> AGUIRunStreamInfo {
        guard let metadata = try await select(connection,runID:binding.runID,write:true) else { throw RunEventStoreError.notFound }
        guard !metadata.expired else { throw RunEventStoreError.expired }
        guard metadata.info.binding == binding,metadata.info.nextSequence == expectedNextSequence,!metadata.info.isTerminal else { throw RunEventStoreError.conflict }
        let publication = try await publicationMetadata(connection,runID:binding.runID)
        switch authorization {
        case .unmanaged:
            guard publication.phase == .unmanaged,terminalPhase == nil else { throw RunEventStoreError.conflict }
        case .owner(let owner):
            guard publication.phase == .running,publication.owner == owner,publication.leaseValid == true else { throw RunEventStoreError.conflict }
        case .stoppedOwner(let owner):
            guard publication.phase == .running,publication.owner == owner else { throw RunEventStoreError.conflict }
        case .expiredLease:
            guard publication.phase == .running,publication.leaseValid == false else { throw RunEventStoreError.conflict }
        }
        let restored = try await history(connection,metadata:metadata)
        var validator = restored.validator,bytes = metadata.info.retainedBytes
        var prepared: [(sequence:Int64,kind:String,text:String)] = []
        var batchBytes = 0
        for event in documents {
            let rows = try await BoundedPostgresQuery.rows(connection,"SELECT \(String(decoding:event.json,as:UTF8.self))::jsonb::text")
            guard let row = rows.first else { throw RunEventStoreError.invalidRequest }
            let text = try row.decode(String.self),data = Data(text.utf8)
            let sequence = validator.nextSequence
            do { try validator.accept(data,sequence:sequence) } catch { throw RunEventStoreError.invalidRequest }
            bytes += Int64(data.count);batchBytes += data.count
            guard bytes <= AGUIRunStreamInfo.maximumRetainedBytes,batchBytes <= 262_144 else { throw RunEventStoreError.limitExceeded }
            prepared.append((sequence,event.kind,text))
        }
        for event in prepared {
            _ = try await BoundedPostgresQuery.rows(connection,"INSERT INTO run_events(actor_id,run_id,sequence,event_type,payload) VALUES(\(actorID),\(binding.runID),\(event.sequence),\(event.kind),\(event.text)::jsonb)")
        }
        let changed = try await BoundedPostgresQuery.rows(connection,"""
            UPDATE run_event_streams SET next_sequence=\(validator.nextSequence),retained_bytes=\(bytes),is_terminal=\(validator.isTerminal),publication_phase=COALESCE(\(terminalPhase?.rawValue)::text,publication_phase)
            WHERE actor_id=\(actorID) AND run_id=\(binding.runID) AND next_sequence=\(expectedNextSequence)
                AND expires_at>clock_timestamp()
                AND (NOT \(authorization.requiresLiveLease) OR execution_lease_until>clock_timestamp())
                AND (NOT \(authorization.requiresExpiredLease) OR execution_lease_until<=clock_timestamp()) RETURNING run_id
            """)
        guard changed.count == 1 else {
            if try await select(connection,runID:binding.runID,write:true)?.expired == true { throw RunEventStoreError.expired }
            throw RunEventStoreError.conflict
        }
        return try AGUIRunStreamInfo(binding:binding,nextSequence:validator.nextSequence,minimumRetainedSequence:metadata.info.minimumRetainedSequence,
            retainedBytes:bytes,isTerminal:validator.isTerminal,retentionSeconds:metadata.info.retentionSeconds,expiresAt:metadata.info.expiresAt)
    }
    /// Reads an archive only from the database, checks terminal runtime and task
    /// identity, then publishes the existing grounded value without execution.
    internal func recoverArchivedCompletion(_ c: PostgresConnection,binding: AGUIRunBinding,at: UTCInstant,authorization: PublicationAuthorization = .expiredLease) async throws -> AGUIRunStreamInfo? {
        let rows = try await BoundedPostgresQuery.rows(c,"""
            SELECT a.answer,t.task::text FROM read_run_completions a
            JOIN agent_runs r ON r.actor_id=a.actor_id AND r.id=a.run_id
            JOIN read_run_tasks t ON t.actor_id=a.actor_id AND t.run_id=a.run_id
            WHERE a.actor_id=\(actorID) AND a.run_id=\(binding.runID) AND a.request_id=\(binding.requestID)
                AND t.request_id=a.request_id AND t.thread_id=\(binding.threadID)
                AND r.state='COMPLETED' AND r.version>a.responding_version
            FOR SHARE OF r
            """)
        guard let row = rows.first else { return nil }
        let (data,taskText) = try row.decode((Data,String).self),task = try ReadRunTaskCodec.decode(taskText)
        _ = try JSONDocument(data,maximumBytes:65_536)
        guard task.request.actorID == actorID,task.request.runID == binding.runID,task.threadID == binding.threadID,
              task.request.requestID == binding.requestID,
              let answer = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              answer["schemaVersion"] as? String == "1",
              (answer["actorId"] as? String).flatMap(UUID.init(uuidString:)) == actorID,
              (answer["requestId"] as? String).flatMap(UUID.init(uuidString:)) == binding.requestID,
              answer["intent"] as? String == task.request.intent.rawValue,
              let text = answer["text"] as? String,let claims = answer["claims"] as? [[String:Any]],
              let evidence = answer["evidence"] as? [[String:Any]] else { throw RunEventStoreError.corruptRecord }
        let subjects = Set(task.request.planningScope.entities.map(\.id))
        guard task.request.planningScope.allowGlobalChanges || (claims+evidence).allSatisfy({
            ($0["subjectId"] as? String).flatMap(UUID.init(uuidString:)).map(subjects.contains) == true
        }) else { throw RunEventStoreError.corruptRecord }
        let messageID = binding.runID.uuidString.lowercased(),timestamp = Int64((at.secondsSince1970*1000).rounded(.down))
        let fields: [(AGUIEventKind,[String:Any])] = [
            (.groundedAnswer,["name":"squidra.grounded_answer.v1","value":answer]),
            (.textStart,["messageId":messageID,"role":"assistant"]),
            (.textContent,["messageId":messageID,"delta":text]),
            (.textEnd,["messageId":messageID]),
            (.runFinished,["threadId":binding.threadID.uuidString.lowercased(),"runId":binding.runID.uuidString.lowercased(),"outcome":["type":"success"]])
        ]
        let documents = try fields.map { kind,fields -> (kind:String,json:Data) in
            var value = fields;value["type"] = kind.rawValue;value["timestamp"] = timestamp
            let bytes = try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])
            guard bytes.count <= AGUIEvent.maximumBytes else { throw RunEventStoreError.limitExceeded }
            return (kind.rawValue,bytes)
        }
        return try await appendDocumentsLocked(c,binding:binding,expectedNextSequence:2,documents:documents,authorization:authorization,terminalPhase:.succeeded)
    }
    public func page(actorID: UUID, runID: UUID, cursor: String?, limit: Int, deadline: ContinuousClock.Instant) async throws -> AGUIRunEventPage {
        guard actorID == self.actorID else { throw RunEventStoreError.notFound }
        guard (1...32).contains(limit) else { throw RunEventStoreError.invalidRequest }
        return try await transaction(deadline) { connection in
            // Look up owned metadata before decoding an untrusted cursor.
            guard let metadata = try await select(connection,runID:runID,write:false) else { throw RunEventStoreError.notFound }
            guard !metadata.expired else { throw RunEventStoreError.expired }
            let info = metadata.info,after: Int64
            do {
                after = try AGUIReplayBounds(actorID:actorID,runID:runID,minimumRetainedSequence:info.minimumRetainedSequence,nextSequence:info.nextSequence).afterSequence(for:cursor)
            } catch AGUIError.cursorOutsideRetention { throw RunEventStoreError.expired }
            catch { throw RunEventStoreError.invalidRequest }
            let restored = try await history(connection,metadata:metadata)
            let records = Array(restored.records.filter { $0.sequence > after }.prefix(limit))
            let last = records.last?.sequence ?? after,through = info.nextSequence-1
            let next = try records.last.map { try AGUIResumeCursor(actorID:actorID,runID:runID,afterSequence:$0.sequence).encoded() }
            return AGUIRunEventPage(info:info,records:records,throughSequence:through,nextCursor:next,hasMore:last < through)
        }
    }
    internal func select(_ connection: PostgresConnection, runID: UUID, write: Bool) async throws -> Metadata? {
        let query: PostgresQuery = write ? """
            SELECT thread_id,request_id,next_sequence,minimum_retained_sequence,retained_bytes,is_terminal,retention_seconds,
                floor(extract(epoch FROM expires_at)*1000000)::bigint,expires_at<=clock_timestamp()
            FROM run_event_streams WHERE actor_id=\(actorID) AND run_id=\(runID) FOR UPDATE
            """ : """
            SELECT thread_id,request_id,next_sequence,minimum_retained_sequence,retained_bytes,is_terminal,retention_seconds,
                floor(extract(epoch FROM expires_at)*1000000)::bigint,expires_at<=clock_timestamp()
            FROM run_event_streams WHERE actor_id=\(actorID) AND run_id=\(runID) FOR SHARE
            """
        let rows = try await BoundedPostgresQuery.rows(connection,query)
        guard let row = rows.first else { return nil }
        guard rows.count == 1 else { throw RunEventStoreError.corruptRecord }
        let (thread,request,next,minimum,bytes,terminal,retention,expires,expired) = try row.decode((UUID,UUID,Int64,Int64,Int64,Bool,Int,Int64,Bool).self)
        let binding = AGUIRunBinding(actorID:actorID,runID:runID,threadID:thread,requestID:request)
        let info = try AGUIRunStreamInfo(binding:binding,nextSequence:next,minimumRetainedSequence:minimum,retainedBytes:bytes,isTerminal:terminal,
            retentionSeconds:retention,expiresAt:UTCInstant(secondsSince1970:Double(expires)/1_000_000))
        return Metadata(info:info,expired:expired)
    }
    internal struct PublicationMetadata: Sendable {
        let phase: RunPublicationPhase, owner: UUID?, leaseExpiresAt: UTCInstant?, leaseValid: Bool?
    }
    internal func publicationMetadata(_ connection: PostgresConnection, runID: UUID) async throws -> PublicationMetadata {
        let rows = try await BoundedPostgresQuery.rows(connection,"""
            SELECT publication_phase,execution_owner,floor(extract(epoch FROM execution_lease_until)*1000000)::bigint,
                execution_lease_until>clock_timestamp() FROM run_event_streams WHERE actor_id=\(actorID) AND run_id=\(runID)
            """)
        guard rows.count == 1,let row = rows.first else { throw RunEventStoreError.notFound }
        do {
            let (raw,owner,lease,valid) = try row.decode((String,UUID?,Int64?,Bool?).self)
            guard let phase = RunPublicationPhase(rawValue:raw),
                  phase == .unmanaged ? (owner == nil && lease == nil && valid == nil) : (owner != nil && lease != nil && valid != nil) else { throw RunEventStoreError.corruptRecord }
            let expires = try lease.map { try UTCInstant(secondsSince1970:Double($0)/1_000_000) }
            return PublicationMetadata(phase:phase,owner:owner,leaseExpiresAt:expires,leaseValid:valid)
        } catch { throw RunEventStoreError.corruptRecord }
    }
    internal func history(_ connection: PostgresConnection, metadata: Metadata) async throws -> (validator:AGUIStreamValidator,records:[AGUIReplayRecord]) {
        let info = metadata.info
        // Partial physical pruning needs a qualified snapshot/rebase mechanism;
        // until that exists, intact retained history is mandatory.
        // The producer validator needs the run start and complete prefix.
        // Retention may remove it, but a suffix must never be replayed as a
        // complete stream or reported as an unrelated storage failure.
        guard info.minimumRetainedSequence == 1 else { throw RunEventStoreError.expired }
        let rows = try await BoundedPostgresQuery.rows(connection,"SELECT sequence,event_type,payload::text FROM run_events WHERE actor_id=\(actorID) AND run_id=\(info.binding.runID) ORDER BY sequence LIMIT 129")
        guard rows.count <= 128,Int64(rows.count) == info.nextSequence-1 else { throw RunEventStoreError.corruptRecord }
        var validator = AGUIStreamValidator(binding:info.binding),records:[AGUIReplayRecord] = [],bytes:Int64 = 0
        do {
            for row in rows {
                let (sequence,kind,text) = try row.decode((Int64,String,String).self),data = Data(text.utf8)
                bytes += Int64(data.count)
                guard bytes <= AGUIRunStreamInfo.maximumRetainedBytes,
                      let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],object["type"] as? String == kind else { throw RunEventStoreError.corruptRecord }
                records.append(try validator.acceptStored(data,sequence:sequence))
            }
            guard bytes == info.retainedBytes,validator.nextSequence == info.nextSequence,validator.isTerminal == info.isTerminal else { throw RunEventStoreError.corruptRecord }
        } catch { throw RunEventStoreError.corruptRecord }
        return (validator,records)
    }
    internal func transaction<Value:Sendable>(_ deadline:ContinuousClock.Instant,_ body:@escaping @Sendable(PostgresConnection) async throws -> Value) async throws -> Value {
        let now = ContinuousClock.now
        guard deadline > now,deadline <= now.advanced(by:.seconds(5)) else { throw RunEventStoreError.timedOut }
        do {
            return try await withThrowingTaskGroup(of:Value.self) { group in
                group.addTask {
                    try await client.withConnection(isolation:nil) { connection in
                        try await withTaskCancellationHandler {
                            try Task.checkCancellation();_ = try await BoundedPostgresQuery.rows(connection,"BEGIN")
                            do {
                                let value = try await body(connection)
                                _ = try await BoundedPostgresQuery.rows(connection,"COMMIT");return value
                            } catch {
                                if (try? await BoundedPostgresQuery.rows(connection,"ROLLBACK")) == nil { connection.close().whenFailure { _ in } }
                                throw error
                            }
                        } onCancel: { connection.close().whenFailure { _ in } }
                    }
                }
                group.addTask { try await ContinuousClock().sleep(until:deadline);throw RunEventStoreError.timedOut }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw RunEventStoreError.unavailable };return value
            }
        } catch is CancellationError { throw Task.isCancelled ? RunEventStoreError.cancelled : RunEventStoreError.timedOut }
        catch let error as RunEventStoreError { throw error }
        catch { throw RunEventStoreError.unavailable }
    }
}
