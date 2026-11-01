import Foundation
import SquidraCognition
import SquidraDomain
import SquidraSecurity
import SquidraTools
import XCTest
@testable import SquidraServer

private struct HostModelFixture: LanguageModel {
    let descriptor:ModelDescriptor
    func generate(_ request:ModelRequest) throws -> ModelResponse { throw ModelProviderError.unavailable }
}
final class ReadHostConfigurationTests: XCTestCase {
    func testOfflineHostRejectsCloudMissingCapabilitiesAndEmptyScope() throws {
        let entity = try PlanningEntity(id:UUID(),label:"entity")
        for descriptor in [
            ModelDescriptor(id:"cloud",modelVersion:"1",location:.cloud,capabilities:[.text,.structuredOutput]),
            ModelDescriptor(id:"text-only",modelVersion:"1",location:.local,capabilities:[.text]),
            ModelDescriptor(id:"cost",modelVersion:"1",location:.local,capabilities:[.text,.structuredOutput],maximumCostMicroUSD:1)
        ] {
            XCTAssertThrowsError(try ReadHostConfiguration(models:[HostModelFixture(descriptor:descriptor)],entities:[entity]))
        }
        XCTAssertThrowsError(try ReadHostConfiguration(models:[],entities:[entity]))
        let model = HostModelFixture(descriptor:ModelDescriptor(id:"local",modelVersion:"1",location:.local,capabilities:[.text,.structuredOutput]))
        XCTAssertThrowsError(try ReadHostConfiguration(models:[model],entities:[]))
        XCTAssertNoThrow(try ReadHostConfiguration(models:[model],entities:[entity]))
    }
    func testCloudHostRequiresExplicitConsentAndTwoAttemptBudget() throws {
        let entity = try PlanningEntity(id:UUID(),label:"entity")
        let model = HostModelFixture(descriptor:ModelDescriptor(id:"cloud",modelVersion:"alias:1",location:.cloud,capabilities:[.text,.structuredOutput],maximumCostMicroUSD:10_000_000))
        XCTAssertThrowsError(try ReadHostConfiguration(models:[model],entities:[entity],maximumCostMicroUSD:20_000_000))
        XCTAssertThrowsError(try ReadHostConfiguration(models:[model],entities:[entity],cloudConsent:true,maximumCostMicroUSD:10_000_000))
        XCTAssertThrowsError(try ReadHostConfiguration(models:[model],entities:[entity],cloudConsent:true,maximumCostMicroUSD:20_000_000,maximumOutputTokens:4097))
        let host = try ReadHostConfiguration(models:[model],entities:[entity],cloudConsent:true,maximumCostMicroUSD:20_000_000)
        XCTAssertTrue(host.cloudConsent);XCTAssertEqual(host.maximumCostMicroUSD,20_000_000)
    }
    func testWorldPolicyCannotGrantForeignActorEntityGlobalReadOrWriteScope() throws {
        let actor = UUID(),entity = try PlanningEntity(id:UUID(),label:"allowed")
        let policy = ServerWorldReadPolicy(actorID:actor,entities:[entity]),definition = try WorldLocationTool.definition()
        func context(actorID:UUID = actor,target:String = "entity:"+entity.id.uuidString.lowercased(),scope:Set<String> = ["world:read"]) -> ActionPolicyContext {
            ActionPolicyContext(actorID:actorID,runID:UUID(),definition:definition,target:target,arguments:Data("{}".utf8),scope:scope,idempotencyKey:"read",deadline:.now.advanced(by:.seconds(1)))
        }
        guard case .allow = try policy.evaluate(context()) else { return XCTFail("Allowed read denied") }
        for value in [context(actorID:UUID()),context(target:"entity:"+UUID().uuidString),context(target:"world:all"),context(scope:["world:write"])] {
            guard case .deny = try policy.evaluate(value) else { return XCTFail("Authority expanded") }
        }
    }
}
