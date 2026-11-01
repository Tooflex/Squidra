import XCTest
@testable import SquidraMeta

final class MetaTextPricingTests: XCTestCase {
    private func usage(_ input: Int, _ output: Int, cached: Int? = nil, reasoning: Int? = nil) -> MetaTextUsage {
        MetaTextUsage(inputTokens:input,outputTokens:output,totalTokens:input+output,cachedInputTokens:cached,reasoningOutputTokens:reasoning)
    }
    func testDatedStandardRatesAndSingleUpwardRounding() throws {
        let spark = try MetaTextPricing.estimate(model:.spark,usage:usage(50,20,cached:10,reasoning:12))
        XCTAssertEqual(spark.costMicroUSD,137);XCTAssertEqual(spark.costBasis,.publishedRateEstimate)
        XCTAssertEqual(spark.costRateID,"meta-standard-text-2026-11-01");XCTAssertFalse(spark.cachedInputWasUnknown)
        XCTAssertEqual(try MetaTextPricing.estimate(model:.wonder,usage:usage(50,20,cached:10)).costMicroUSD,562)
        XCTAssertEqual(try MetaTextPricing.estimate(model:.spark,usage:usage(1,0,cached:0)).costMicroUSD,2)
        XCTAssertEqual(try MetaTextPricing.estimate(model:.spark,usage:usage(0,0,cached:0)).costMicroUSD,0)
        XCTAssertEqual(try MetaTextPricing.estimate(model:.spark,usage:usage(1_000_000,0,cached:0)).costMicroUSD,1_250_000)
        XCTAssertEqual(try MetaTextPricing.estimate(model:.spark,usage:usage(1_000_000,0,cached:1_000_000)).costMicroUSD,150_000)
    }
    func testMissingCacheUsesFullInputRateWithoutInventingUsage() throws {
        let result = try MetaTextPricing.estimate(model:.spark,usage:usage(50,20))
        XCTAssertEqual(result.costMicroUSD,148);XCTAssertTrue(result.cachedInputWasUnknown)
        let measuredZero = try MetaTextPricing.estimate(model:.spark,usage:usage(50,20,cached:0))
        XCTAssertEqual(measuredZero.costMicroUSD,result.costMicroUSD);XCTAssertFalse(measuredZero.cachedInputWasUnknown)
    }
    func testInvalidAndExtremeUsageRejectsBeforeArithmetic() throws {
        let variants = [usage(-1,2),usage(1,4097),usage(1_048_577,0),usage(1,0,cached:2),usage(1,0,cached:-1),usage(1,2,reasoning:3),usage(1,2,reasoning:-1),
            MetaTextUsage(inputTokens:Int.max,outputTokens:Int.max,totalTokens:0,cachedInputTokens:nil,reasoningOutputTokens:nil),
            MetaTextUsage(inputTokens:1,outputTokens:1,totalTokens:3,cachedInputTokens:nil,reasoningOutputTokens:nil)]
        for value in variants { XCTAssertThrowsError(try MetaTextPricing.estimate(model:.spark,usage:value)) { XCTAssertEqual($0 as? MetaResponsesError,.invalidResponse) } }
        XCTAssertEqual(try MetaTextPricing.estimate(model:.wonder,usage:usage(1_048_576,4096,cached:0)).costMicroUSD,4_276_224)
    }
}
