import Foundation
import SquidraDomain
import XCTest
@testable import SquidraCognition

private struct CostModel: LanguageModel {
    let descriptor: ModelDescriptor
    let basis: ModelCostBasis, rate: String?, amount: Int64
    init(_ basis: ModelCostBasis, rate: String? = nil, amount: Int64 = 3, cloud: Bool = false) {
        self.basis = basis;self.rate = rate;self.amount = amount
        descriptor = ModelDescriptor(id:"cost.fixture",modelVersion:"1",location:cloud ? .cloud : .local,capabilities:[.text],maximumCostMicroUSD:10)
    }
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        ModelResponse(requestID:request.id,modelID:descriptor.id,modelVersion:descriptor.modelVersion,text:"{}",outputTokens:1,costMicroUSD:amount,costBasis:basis,costRateID:rate)
    }
}
final class ModelCostTests: XCTestCase, @unchecked Sendable {
    private func route(_ model: CostModel) async throws -> RoutedModelResponse {
        let clock = try FixedClock(instant:UTCInstant(secondsSince1970:0),timeZone:IANATimeZone(identifier:"UTC"))
        let request = try ModelRequest(id:UUID(),messages:[.init(role:.user,content:"{}")],cloudConsent:true,maximumCostMicroUSD:10,deadline:UTCInstant(secondsSince1970:30))
        return try await ModelRouter(models:[model],clock:clock).generate(request)
    }
    private func plan(_ routing: RoutedModelResponse) throws -> PlannedRead {
        PlannedRead(proposal:ReadProposal(tool:try ToolID(namespace:"world",name:"location",version:"1.0.0"),target:"fixture",arguments:Data("{}".utf8)),routing:routing)
    }
    private func encoded(_ routing: RoutedModelResponse) throws -> [Data] {
        [try ReadPlanArchive.encode(plan(routing)),try ReadAnswerArchive.encode(routing)]
    }
    private func decoded(_ data: Data, index: Int) throws -> RoutedModelResponse {
        try index == 0 ? ReadPlanArchive.routing(data) : ReadAnswerArchive.decode(data)
    }
    func testRouterPreservesValidatedEvidenceAndRejectsFalseLocalZero() async throws {
        for model in [CostModel(.unspecified),CostModel(.providerReported),CostModel(.localZero,amount:0),CostModel(.publishedRateEstimate,rate:"meta-standard-text-2026-11-01",cloud:true)] {
            let result = try await route(model)
            XCTAssertEqual(result.response.costBasis,model.basis);XCTAssertEqual(result.response.costRateID,model.rate)
            XCTAssertEqual(result.reservedCostUpperBoundMicroUSD,10) // Estimate does not reduce reservation.
        }
        for model in [CostModel(.localZero),CostModel(.localZero,amount:0,cloud:true),CostModel(.publishedRateEstimate),CostModel(.publishedRateEstimate,rate:"private value\n"),CostModel(.publishedRateEstimate,rate:String(repeating:"a",count:97)),CostModel(.providerReported,rate:"unexpected"),CostModel(.unspecified,rate:"unexpected")] {
            do { _ = try await route(model);XCTFail() } catch { XCTAssertEqual(error as? ModelRoutingError,.invalidResponse) }
        }
    }
    func testVersionTwoArchivesPreserveEachCostBasis() async throws {
        for model in [CostModel(.unspecified),CostModel(.providerReported),CostModel(.localZero,amount:0),CostModel(.publishedRateEstimate,rate:"schedule-1")] {
            let routing = try await route(model)
            for (index,data) in try encoded(routing).enumerated() {
                let wire = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
                XCTAssertEqual(wire["version"] as? Int,2);XCTAssertEqual(wire["costBasis"] as? String,model.basis.rawValue)
                let restored = try decoded(data,index:index)
                XCTAssertEqual(restored.response.costBasis,model.basis);XCTAssertEqual(restored.response.costRateID,model.rate)
                XCTAssertEqual(restored.response.costMicroUSD,model.amount);XCTAssertEqual(restored.reservedCostUpperBoundMicroUSD,10)
            }
        }
    }
    func testLegacyArchivesRemainUnspecifiedAndUpgradeWithoutInventedProvenance() async throws {
        let routing = try await route(CostModel(.providerReported))
        for (index,data) in try encoded(routing).enumerated() {
            var wire = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
            wire["version"] = 1;wire.removeValue(forKey:"costBasis");wire.removeValue(forKey:"costRateID")
            let restored = try decoded(JSONSerialization.data(withJSONObject:wire),index:index)
            XCTAssertEqual(restored.response.costBasis,.unspecified);XCTAssertNil(restored.response.costRateID)
            XCTAssertEqual(restored.response.costMicroUSD,3)
            let rewritten = try encoded(restored)[index]
            XCTAssertEqual(try decoded(rewritten,index:index).response.costBasis,.unspecified)
        }
    }
    func testArchiveMetadataCannotBeOmittedDowngradedOrForged() async throws {
        let routing = try await route(CostModel(.publishedRateEstimate,rate:"schedule-1"))
        for (index,data) in try encoded(routing).enumerated() {
            let original = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
            var variants: [[String:Any]] = []
            var value=original;value.removeValue(forKey:"costBasis");variants.append(value)
            value=original;value["version"]=1;variants.append(value)
            value=original;value["version"]=3;variants.append(value)
            value=original;value["costBasis"]="invoice_probably";variants.append(value)
            value=original;value["costBasis"]="local_zero";value.removeValue(forKey:"costRateID");variants.append(value)
            value=original;value.removeValue(forKey:"costRateID");variants.append(value)
            value=original;value["costRateID"]="bad\nlabel";variants.append(value)
            value=original;value["extra"]=true;variants.append(value)
            for wire in variants { XCTAssertThrowsError(try decoded(JSONSerialization.data(withJSONObject:wire),index:index)) }
        }
    }
}
