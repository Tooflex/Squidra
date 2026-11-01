import Foundation
import PostgresNIO
import SquidraWorld

public enum MediaRetentionError: Error, Sendable { case invalidRequest, conflict, capacity, unavailable }
public struct MediaRetentionPolicy: Sendable {
    public let seconds: Int
    public init(seconds: Int = 60) throws {
        guard (1...3600).contains(seconds) else { throw MediaRetentionError.invalidRequest }
        self.seconds = seconds
    }
}
public struct RetainedMedia: Sendable {
    public enum State: String, Sendable { case available, expired, erased }
    public let frameID: UUID
    public let expiresMicroseconds: Int64
    public let state: State
    public let bytes: Data?
}

/// Trusted-host, opt-in storage. Actor identity and wall clock come from the host,
/// never model arguments. No automatic upload retention or tool/HTTP exposure.
public struct PostgresMediaRetention: Sendable {
    private enum Admission: Sendable { case stored, conflict, capacity }
    public let actorID: UUID
    private let repository: PostgresWorldRepository
    public init(actorID: UUID, client: PostgresClient) {
        self.actorID = actorID; repository = PostgresWorldRepository(client: client)
    }
    private func validTime(_ value: Int64) throws {
        guard (0...253_402_300_800_000_000).contains(value) else { throw MediaRetentionError.invalidRequest }
    }
    /// Same frame and exact content/policy is idempotent while available.
    /// An unavailable reference can never be reused to store new bytes.
    public func retain(frameID: UUID, bytes: Data, mediaType: String, capturedMicroseconds: Int64,
                       policy: MediaRetentionPolicy, deadline: ContinuousClock.Instant) async throws {
        try validTime(capturedMicroseconds)
        guard capturedMicroseconds <= 253_402_296_000_000_000, (1...65_536).contains(bytes.count), ["image/png", "image/jpeg"].contains(mediaType) else { throw MediaRetentionError.invalidRequest }
        let expiry = capturedMicroseconds + Int64(policy.seconds) * 1_000_000
        // Hex is bounded to 128 KiB and bound as data, never SQL text interpolation.
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let result: Admission = try await transaction(deadline) { c in
            _ = try await BoundedPostgresQuery.rows(c,"SELECT pg_advisory_xact_lock(hashtextextended(\(actorID.uuidString),1936818048))")
            let previous = try await BoundedPostgresQuery.rows(c,"""
                SELECT blob IS NOT NULL AND blob=decode(\(hex),'hex') AND captured_us=\(capturedMicroseconds)
                    AND expires_us=\(expiry) AND media_type=\(mediaType)
                FROM retained_media WHERE actor_id=\(actorID) AND frame_id=\(frameID) FOR UPDATE
                """)
            if let row = previous.first {
                return try row.decode(Bool.self) ? .stored : .conflict
            }
            let count = try await BoundedPostgresQuery.rows(c,"SELECT count(*)::bigint FROM retained_media WHERE actor_id=\(actorID) AND blob IS NOT NULL")
            guard try count[0].decode(Int64.self) < 128 else { return .capacity }
            _ = try await BoundedPostgresQuery.rows(c,"""
                INSERT INTO retained_media(actor_id,frame_id,captured_us,expires_us,media_type,byte_count,blob)
                VALUES(\(actorID),\(frameID),\(capturedMicroseconds),\(expiry),\(mediaType),\(bytes.count),decode(\(hex),'hex'))
                """)
            return .stored
        }
        // Business rejections occur before any mutation and survive repository
        // error sanitization without changing its transaction contract.
        switch result {
        case .stored: return
        case .conflict: throw MediaRetentionError.conflict
        case .capacity: throw MediaRetentionError.capacity
        }
    }
    /// Expired bytes are never returned, even before a purge worker has run.
    public func load(frameID: UUID, nowMicroseconds: Int64, deadline: ContinuousClock.Instant) async throws -> RetainedMedia? {
        try validTime(nowMicroseconds)
        return try await transaction(deadline) { c in
            let rows = try await BoundedPostgresQuery.rows(c,"""
                SELECT expires_us,CASE WHEN reason IS NOT NULL THEN reason WHEN expires_us<=\(nowMicroseconds) THEN 'expired' ELSE 'available' END,
                    CASE WHEN blob IS NOT NULL AND expires_us>\(nowMicroseconds) THEN encode(blob,'hex') ELSE '' END
                FROM retained_media WHERE actor_id=\(actorID) AND frame_id=\(frameID)
                """)
            guard let row = rows.first else { return nil }
            let (expiry,state,hex) = try row.decode((Int64,String,String).self)
            guard let status = RetainedMedia.State(rawValue:state),hex.count <= 131_072,hex.count % 2 == 0 else { throw MediaRetentionError.unavailable }
            var decoded = Data(); let chars = Array(hex.utf8)
            for i in stride(from:0,to:chars.count,by:2) {
                guard let byte = UInt8(String(decoding:chars[i...i+1],as:UTF8.self),radix:16) else { throw MediaRetentionError.unavailable }
                decoded.append(byte)
            }
            return RetainedMedia(frameID:frameID,expiresMicroseconds:expiry,state:status,bytes:status == .available ? decoded : nil)
        }
    }
    /// Bounded batch. The host schedules repeated calls; no hidden background task.
    public func purge(nowMicroseconds: Int64, deadline: ContinuousClock.Instant) async throws -> Int {
        try validTime(nowMicroseconds)
        return try await transaction(deadline) { c in
            let rows = try await BoundedPostgresQuery.rows(c,"""
                WITH due AS (SELECT frame_id FROM retained_media WHERE actor_id=\(actorID) AND blob IS NOT NULL
                    AND expires_us<=\(nowMicroseconds) ORDER BY expires_us,frame_id LIMIT 128 FOR UPDATE SKIP LOCKED)
                UPDATE retained_media m SET blob=NULL,unavailable_us=\(nowMicroseconds),reason='expired'
                FROM due WHERE m.actor_id=\(actorID) AND m.frame_id=due.frame_id RETURNING m.frame_id
                """)
            return rows.count
        }
    }
    /// Authorized host erasure of this actor's one retained blob. This is not
    /// physical erasure of WAL, backups, immutable facts, or personal data elsewhere.
    public func erase(frameID: UUID, nowMicroseconds: Int64, deadline: ContinuousClock.Instant) async throws -> Bool {
        try validTime(nowMicroseconds)
        return try await transaction(deadline) { c in
            let rows = try await BoundedPostgresQuery.rows(c,"""
                UPDATE retained_media SET blob=NULL,unavailable_us=\(nowMicroseconds),reason='erased'
                WHERE actor_id=\(actorID) AND frame_id=\(frameID) AND captured_us<=\(nowMicroseconds) AND blob IS NOT NULL RETURNING frame_id
                """)
            return !rows.isEmpty
        }
    }
    private func transaction<T: Sendable>(_ deadline: ContinuousClock.Instant,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> T) async throws -> T {
        do { return try await repository.transaction(deadline:deadline,body) }
        catch is CancellationError { throw CancellationError() }
        catch let error as MediaRetentionError { throw error }
        catch { throw MediaRetentionError.unavailable }
    }
}
