import Foundation
import SquidraAgentRuntime
import SquidraCognition
import SquidraDomain

/// Versioned bounded storage DTO. Double bit strings preserve exact deadlines
/// and windows across JSONB; decoding reconstructs all validated value types.
enum ReadRunTaskCodec {
    private struct Entity: Codable { let id: UUID, label: String }
    private struct Wire: Codable {
        let version: Int
        let actor: UUID, run: UUID, trace: UUID, request: UUID, thread: UUID
        let question: String, intent: String, deadlineBits: String, windowBits: String
        let entities: [Entity], scope: [String]
        let global: Bool, cloudConsent: Bool, fallback: Bool
        let preferredModel: String?
        let maximumCost: Int64, maximumTokens: Int
        let budget: RunBudget
    }
    static func encode(_ task: StoredReadRunTask) throws -> String {
        let r = task.request,o = r.modelOptions
        guard !r.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,r.question.utf8.count <= 4096,
              !r.question.contains("\0"),r.effectiveToolScope == ["world:read"],o.maximumCostMicroUSD >= 0,
              (1...2048).contains(o.maximumOutputTokens),o.preferredModelID.map({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains("\0") }) ?? true else { throw ReadRunTaskError.invalidState }
        _ = try RunBudget(steps:r.budget.steps,calls:r.budget.calls,depth:r.budget.depth,retries:r.budget.retries,repetitions:r.budget.repetitions,activeMilliseconds:r.budget.activeMilliseconds)
        let wire = Wire(version:1,actor:r.actorID,run:r.runID,trace:r.traceID,request:r.requestID,thread:task.threadID,
            question:r.question,intent:r.intent.rawValue,deadlineBits:String(o.deadline.secondsSince1970.bitPattern),
            windowBits:String(r.planningScope.maximumWindowSeconds.bitPattern),entities:r.planningScope.entities.map { Entity(id:$0.id,label:$0.label) },
            scope:r.effectiveToolScope.sorted(),global:r.planningScope.allowGlobalChanges,cloudConsent:o.cloudConsent,fallback:o.allowFallback,
            preferredModel:o.preferredModelID,maximumCost:o.maximumCostMicroUSD,maximumTokens:o.maximumOutputTokens,budget:r.budget)
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let data = try encoder.encode(wire)
        guard data.count <= 16_384 else { throw ReadRunTaskError.invalidState }
        return String(decoding:data,as:UTF8.self)
    }
    static func decode(_ text: String) throws -> StoredReadRunTask {
        do {
            let data = Data(text.utf8)
            _ = try JSONDocument(data,maximumBytes:16_384)
            let wire = try JSONDecoder().decode(Wire.self,from:data)
            guard wire.version == 1,let intent = AnswerIntent(rawValue:wire.intent),
                  let deadline = UInt64(wire.deadlineBits),let window = UInt64(wire.windowBits) else { throw ReadRunTaskError.invalidState }
            let request = try ReadRunRequest(actorID:wire.actor,runID:wire.run,traceID:wire.trace,requestID:wire.request,
                question:wire.question,planningScope:ReadPlanningScope(entities:wire.entities.map { try PlanningEntity(id:$0.id,label:$0.label) },
                    allowGlobalChanges:wire.global,maximumWindowSeconds:Double(bitPattern:window)),effectiveToolScope:Set(wire.scope),intent:intent,
                modelOptions:ReadPlanningOptions(preferredModelID:wire.preferredModel,cloudConsent:wire.cloudConsent,allowFallback:wire.fallback,
                    maximumCostMicroUSD:wire.maximumCost,maximumOutputTokens:wire.maximumTokens,deadline:UTCInstant(secondsSince1970:Double(bitPattern:deadline))),budget:wire.budget)
            let task = StoredReadRunTask(request:request,threadID:wire.thread)
            let canonical = Data(try encode(task).utf8)
            guard let original = try JSONSerialization.jsonObject(with:data) as? NSDictionary,
                  let rebuilt = try JSONSerialization.jsonObject(with:canonical) as? NSDictionary,original == rebuilt else { throw ReadRunTaskError.invalidState }
            return task
        } catch { throw ReadRunTaskError.invalidState }
    }
}
