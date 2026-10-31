import Foundation
import PostgresNIO
import SquidraDomain
import SquidraProtocols

/// Fixed actor boundary. Replay is read-only and cannot resume an agent/action.
public struct PostgresRunEventStore: RunEventStore {
    private let client: PostgresClient
    public let actorID: UUID
    public init(client: PostgresClient, actorID: UUID) { self.client = client;self.actorID = actorID }
    private struct Metadata: Sendable { let info: AGUIRunStreamInfo;let expired: Bool }
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
            guard let metadata = try await select(connection,runID:binding.runID,write:true) else { throw RunEventStoreError.notFound }
            guard !metadata.expired else { throw RunEventStoreError.expired }
            guard metadata.info.binding == binding,metadata.info.nextSequence == expectedNextSequence,!metadata.info.isTerminal else { throw RunEventStoreError.conflict }
            let restored = try await history(connection,metadata:metadata)
            var validator = restored.validator,bytes = metadata.info.retainedBytes
            var prepared: [(sequence:Int64,kind:String,text:String)] = []
            var batchBytes = 0
            for event in events {
                let rows = try await BoundedPostgresQuery.rows(connection,"SELECT \(String(decoding:event.json,as:UTF8.self))::jsonb::text")
                guard let row = rows.first else { throw RunEventStoreError.invalidRequest }
                let text = try row.decode(String.self),data = Data(text.utf8)
                let sequence = validator.nextSequence
                do { try validator.accept(data,sequence:sequence) } catch { throw RunEventStoreError.invalidRequest }
                bytes += Int64(data.count);batchBytes += data.count
                guard bytes <= AGUIRunStreamInfo.maximumRetainedBytes,batchBytes <= 262_144 else { throw RunEventStoreError.limitExceeded }
                prepared.append((sequence,event.kind.rawValue,text))
            }
            for event in prepared {
                _ = try await BoundedPostgresQuery.rows(connection,"INSERT INTO run_events(actor_id,run_id,sequence,event_type,payload) VALUES(\(actorID),\(binding.runID),\(event.sequence),\(event.kind),\(event.text)::jsonb)")
            }
            let changed = try await BoundedPostgresQuery.rows(connection,"""
                UPDATE run_event_streams SET next_sequence=\(validator.nextSequence),retained_bytes=\(bytes),is_terminal=\(validator.isTerminal)
                WHERE actor_id=\(actorID) AND run_id=\(binding.runID) AND next_sequence=\(expectedNextSequence) RETURNING run_id
                """)
            guard changed.count == 1 else { throw RunEventStoreError.conflict }
            return try AGUIRunStreamInfo(binding:binding,nextSequence:validator.nextSequence,minimumRetainedSequence:metadata.info.minimumRetainedSequence,
                retainedBytes:bytes,isTerminal:validator.isTerminal,retentionSeconds:metadata.info.retentionSeconds,expiresAt:metadata.info.expiresAt)
        }
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
    private func select(_ connection: PostgresConnection, runID: UUID, write: Bool) async throws -> Metadata? {
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
    private func history(_ connection: PostgresConnection, metadata: Metadata) async throws -> (validator:AGUIStreamValidator,records:[AGUIReplayRecord]) {
        let info = metadata.info
        // Partial physical pruning needs a qualified snapshot/rebase mechanism;
        // until that exists, intact retained history is mandatory.
        guard info.minimumRetainedSequence == 1 else { throw RunEventStoreError.corruptRecord }
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
    private func transaction<Value:Sendable>(_ deadline:ContinuousClock.Instant,_ body:@escaping @Sendable(PostgresConnection) async throws -> Value) async throws -> Value {
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
