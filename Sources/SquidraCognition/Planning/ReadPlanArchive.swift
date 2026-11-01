import Foundation
import SquidraDomain

/// Private run data. Restoration revalidates the proposal and never grants tool authority.
public enum ReadPlanArchive {
    private struct Wire: Codable {
        let version: Int,requestID: UUID,modelID: String,modelVersion: String,text: String
        let outputTokens: Int,cost: Int64,attempted: [String],reserved: Int64
        let costBasis: ModelCostBasis?, costRateID: String?
    }
    public static func encode(_ plan: PlannedRead) throws -> Data {
        let r = plan.routing.response
        let wire = Wire(version:2,requestID:r.requestID,modelID:r.modelID,modelVersion:r.modelVersion,text:r.text,
            outputTokens:r.outputTokens,cost:r.costMicroUSD,attempted:plan.routing.attemptedModelIDs,reserved:plan.routing.reservedCostUpperBoundMicroUSD,costBasis:r.costBasis,costRateID:r.costRateID)
        try validate(wire)
        return try encode(wire)
    }
    private static func encode(_ wire: Wire) throws -> Data {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let data = try encoder.encode(wire)
        guard data.count <= 65_536 else { throw ReadPlanningError.invalidProposal };return data
    }
    private static func validate(_ w: Wire) throws {
        guard (w.version == 1 && w.costBasis == nil && w.costRateID == nil) || (w.version == 2 && w.costBasis != nil),
              (w.costBasis ?? .unspecified).validates(amount:w.cost,rateID:w.costRateID),!w.modelID.isEmpty,w.modelID.utf8.count <= 128,!w.modelVersion.isEmpty,w.modelVersion.utf8.count <= 128,
              !w.text.isEmpty,w.text.utf8.count <= 16_384,(1...2048).contains(w.outputTokens),w.cost >= 0,w.reserved >= w.cost,
              (1...256).contains(w.attempted.count),w.attempted.last == w.modelID,Set(w.attempted).count == w.attempted.count,
              w.attempted.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw ReadPlanningError.invalidProposal }
    }
    static func routing(_ data: Data) throws -> RoutedModelResponse {
        do {
            let document = try JSONDocument(data,maximumBytes:65_536)
            guard !document.containsNUL else { throw ReadPlanningError.invalidProposal }
            let w = try JSONDecoder().decode(Wire.self,from:data);try validate(w)
            guard try JSONSerialization.jsonObject(with:data) as? NSDictionary == JSONSerialization.jsonObject(with:encode(w)) as? NSDictionary else { throw ReadPlanningError.invalidProposal }
            return RoutedModelResponse(response:ModelResponse(requestID:w.requestID,modelID:w.modelID,modelVersion:w.modelVersion,text:w.text,
                outputTokens:w.outputTokens,costMicroUSD:w.cost,costBasis:w.costBasis ?? .unspecified,costRateID:w.costRateID),attemptedModelIDs:w.attempted,reservedCostUpperBoundMicroUSD:w.reserved)
        } catch { throw ReadPlanningError.invalidProposal }
    }
}
