import Foundation
import PostgresNIO

public enum StructuralExportError: Error, Sendable { case invalidCursor, invalidLimit, unavailable }
public struct StructuralExportCursor: Codable, Sendable {
    public let actorID: UUID
    public let afterSequence: Int64
    public let highWater: Int64
    public init(actorID: UUID, afterSequence: Int64, highWater: Int64) throws {
        guard afterSequence >= 0,highWater >= afterSequence else { throw StructuralExportError.invalidCursor }
        self.actorID=actorID;self.afterSequence=afterSequence;self.highWater=highWater
    }
}
public struct StructuralExportPage: Codable, Sendable {
    public struct Event: Codable, Sendable {
        public let id: UUID
        public let sequence: Int64
        public let streamID: UUID
        public let streamVersion: Int64
        public let observedMicroseconds: Int64
        public let payloadVersion: Int
    }
    public struct Fact: Codable, Sendable {
        public let id: UUID
        public let eventID: UUID
        public let subjectID: UUID
        public let objectID: UUID
        public let frameID: UUID
        public let validFromMicroseconds: Int64
        public let validToMicroseconds: Int64?
        public let confidence: Double
    }
    public let schemaVersion: Int
    public let scope: String
    public let actorID: UUID
    public let highWater: Int64
    public let events: [Event]
    public let facts: [Fact]
    public let next: StructuralExportCursor?
}

/// Structural journal evidence only. No raw JSON, labels, strings, media or
/// runtime prompts. The trusted host binds actor identity and authorizes export.
public struct PostgresStructuralExport: Sendable {
    public let actorID: UUID
    private let repository: PostgresWorldRepository
    public init(actorID: UUID, client: PostgresClient) { self.actorID=actorID;repository=PostgresWorldRepository(client:client) }
    public func page(cursor: StructuralExportCursor? = nil, limit: Int = 32,
                     deadline: ContinuousClock.Instant) async throws -> StructuralExportPage {
        guard (1...64).contains(limit) else { throw StructuralExportError.invalidLimit }
        if let cursor {
            // Revalidate decoded cursors too: Codable decoding does not call the initializer.
            guard cursor.actorID == actorID,cursor.afterSequence >= 0,cursor.highWater >= cursor.afterSequence else { throw StructuralExportError.invalidCursor }
        }
        do {
            return try await repository.transaction(deadline:deadline) { c in
                _ = try await BoundedPostgresQuery.rows(c,"SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
                let high: Int64
                if let cursor { high=cursor.highWater }
                else {
                    let rows=try await BoundedPostgresQuery.rows(c,"SELECT coalesce(max(sequence),0)::bigint FROM world_events WHERE actor_id=\(actorID)")
                    high=try rows[0].decode(Int64.self)
                }
                let rows=try await BoundedPostgresQuery.rows(c,"""
                    SELECT event_id,sequence,stream_id,stream_version,floor(extract(epoch FROM observed_at)*1000000)::bigint,payload_version
                    FROM world_events WHERE actor_id=\(actorID) AND sequence>\(cursor?.afterSequence ?? 0) AND sequence<=\(high)
                    ORDER BY sequence LIMIT \(limit+1)
                    """)
                var events=[StructuralExportPage.Event]()
                for row in rows.prefix(limit) {
                    let (id,sequence,stream,version,observed,payloadVersion)=try row.decode((UUID,Int64,UUID,Int64,Int64,Int).self)
                    events.append(.init(id:id,sequence:sequence,streamID:stream,streamVersion:version,observedMicroseconds:observed,payloadVersion:payloadVersion))
                }
                var facts=[StructuralExportPage.Fact]()
                if !events.isEmpty {
                    let ids=events.map(\.id)
                    let factRows=try await BoundedPostgresQuery.rows(c,"""
                        SELECT f.id,f.provenance_event_id,f.subject_id,f.object_id,f.frame_id,
                            floor(extract(epoch FROM f.valid_from)*1000000)::bigint,
                            floor(extract(epoch FROM f.valid_to)*1000000)::bigint,f.confidence
                        FROM spatial_facts f JOIN world_events e ON e.actor_id=f.actor_id AND e.event_id=f.provenance_event_id
                        WHERE f.actor_id=\(actorID) AND e.actor_id=\(actorID) AND f.provenance_event_id=ANY(\(ids))
                        ORDER BY e.sequence,f.id LIMIT 129
                        """)
                    // Never silently truncate associated facts or allocate an unbounded export.
                    guard factRows.count <= 128 else { throw StructuralExportError.unavailable }
                    for row in factRows {
                        let (id,event,subject,object,frame,from,to,confidence)=try row.decode((UUID,UUID,UUID,UUID,UUID,Int64,Int64?,Double).self)
                        facts.append(.init(id:id,eventID:event,subjectID:subject,objectID:object,frameID:frame,validFromMicroseconds:from,validToMicroseconds:to,confidence:confidence))
                    }
                }
                let next=rows.count>limit ? try StructuralExportCursor(actorID:actorID,afterSequence:events.last!.sequence,highWater:high) : nil
                return StructuralExportPage(schemaVersion:1,scope:"journal-structure",actorID:actorID,highWater:high,events:events,facts:facts,next:next)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw StructuralExportError.unavailable }
    }
}
