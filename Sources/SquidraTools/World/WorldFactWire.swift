import Foundation
import SquidraDomain
import SquidraWorld

/// Shared wire encoding; storage microseconds stay internal to query ports.
internal enum WorldFactWire {
    static func contains(_ interval: FactInterval, _ micros: Int64) -> Bool {
        interval.fromMicroseconds <= micros && (interval.toMicroseconds.map { micros < $0 } ?? true)
    }
    static func interval(_ value: FactInterval) throws -> [String: Any] {
        ["from": try RFC3339.format(value.from), "to": try value.to.map(RFC3339.format) as Any? ?? NSNull()]
    }
    static func encode(_ fact: WorldLocationFact, actor: UUID, subject: UUID? = nil) throws -> [String: Any] {
        guard fact.actorID == actor, subject.map({ fact.subjectID == $0 }) ?? true,
              fact.id == fact.sourceEventID, !fact.sourceID.isEmpty, fact.sourceID.utf8.count <= 256,
              !fact.sourceID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              fact.transaction.from == fact.timestamps.recordedAt else { throw ToolError.invalidOutput }
        return ["id": fact.id.uuidString.lowercased(), "subjectId": fact.subjectID.uuidString.lowercased(),
                "locationId": fact.locationID.uuidString.lowercased(), "frameId": fact.frameID.uuidString.lowercased(),
                "sourceEventId": fact.sourceEventID.uuidString.lowercased(), "source": fact.sourceID,
                "confidence": fact.confidence.value, "basis": fact.basis.rawValue,
                "occurredAt": try fact.timestamps.occurredAt.map(RFC3339.format) as Any? ?? NSNull(),
                "observedAt": try RFC3339.format(fact.timestamps.observedAt), "recordedAt": try RFC3339.format(fact.timestamps.recordedAt),
                "timeZone": fact.timestamps.timeZone.identifier, "valid": try interval(fact.valid), "transaction": try interval(fact.transaction)]
    }
}
