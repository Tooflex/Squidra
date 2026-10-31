import Foundation

/// ADR-007 v1. Details are omitted until a route declares a filtered detail schema.
public struct APIErrorEnvelope: Codable, Sendable {
    public let schemaVersion: String
    public let code: String
    public let message: String
    public let requestId: UUID

    public init(code: String, message: String, requestId: UUID) {
        self.schemaVersion = "1"
        self.code = code
        self.message = message
        self.requestId = requestId
    }
}

/// Sequence cursor, not an offset. Storage must also filter by the authenticated actor.
public struct PageRequest: Sendable, Equatable {
    public enum Invalid: Error { case limit, cursor }
    public let limit: Int
    public let after: Int64?

    public init(limit: String? = nil, after: String? = nil) throws {
        if let limit {
            guard let value = Int(limit), (1...100).contains(value), String(value) == limit else {
                throw Invalid.limit
            }
            self.limit = value
        } else { self.limit = 50 }
        if let after {
            guard let value = Int64(after), value > 0, String(value) == after else { throw Invalid.cursor }
            self.after = value
        } else { self.after = nil }
    }
}
