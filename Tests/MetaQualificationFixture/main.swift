import Foundation
import Crypto
import SquidraCognition
import SquidraMeta
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct ExpectedAnswer: Decodable { let ok: Bool }
private enum Failure: Error { case invalidConfiguration, unexpectedAnswer }
private actor RecordingTransport: MetaResponsesTransport {
    let inner: MetaHTTPSResponseTransport
    private(set) var response: MetaHTTPResponse?
    private var called = false
    init(_ inner: MetaHTTPSResponseTransport) { self.inner = inner }
    func post(_ body: Data, maximumResponseBytes: Int, deadline: ContinuousClock.Instant) async throws -> MetaHTTPResponse {
        guard !called else { throw MetaResponsesError.invalidRequest };called = true
        let result = try await inner.post(body,maximumResponseBytes:maximumResponseBytes,deadline:deadline)
        response = result;return result
    }
}
private func key(at path: String) throws -> String {
    let fd = open(path,O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw Failure.invalidConfiguration }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd,&info) == 0,info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          info.st_uid == getuid(),info.st_mode & 0o777 == 0o600,(1...4096).contains(info.st_size) else { throw Failure.invalidConfiguration }
    let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:false)
    let data = try handle.read(upToCount:4097) ?? Data()
    guard data.count == info.st_size,let text = String(data:data,encoding:.ascii) else { throw Failure.invalidConfiguration }
    return text
}
private func emit(_ value: [String:Any]) throws {
    let data = try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
    FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]))
}
private func run() async throws -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst()),env = ProcessInfo.processInfo.environment
    guard args.count == 2,env["SQUIDRA_META_LIVE_AUTHORIZED"] == "1",
          let reservation = env["SQUIDRA_META_RESERVATION_ID"],UUID(uuidString:reservation) != nil,
          ["spark","wonder"].contains(args[0]) else { throw Failure.invalidConfiguration }
    let model: MetaTextModel = args[0] == "spark" ? .spark : .wonder
    let transport = try RecordingTransport(MetaHTTPSResponseTransport(apiKey:key(at:args[1])))
    var report: [String:Any] = ["schemaVersion":1,"model":model.rawValue,"reservationID":reservation,"maximumOutputTokens":64,
        "prompt":"Return exactly {\"ok\":true} as a JSON object.","store":false,"stream":false,"tools":[],"checkedAt":ISO8601DateFormatter().string(from:Date())]
    var exitCode: Int32 = 0
    do {
        let result = try await MetaResponsesClient(model:model,transport:transport).generate(
            messages:[.init(role:.user,content:"Return exactly {\"ok\":true} as a JSON object.")],
            maximumOutputTokens:64,cloudConsent:true,deadline:.now.advanced(by:.seconds(25)))
        let value = try JSONSerialization.jsonObject(with:Data(result.text.utf8))
        guard let object = value as? NSDictionary,object.count == 1,
              try JSONDecoder().decode(ExpectedAnswer.self,from:Data(result.text.utf8)).ok else { throw Failure.unexpectedAnswer }
        let cost = try MetaTextPricing.estimate(model:model,usage:result.usage)
        report["outcome"] = "passed";report["text"] = result.text
        report["inputTokens"] = result.usage.inputTokens;report["outputTokens"] = result.usage.outputTokens
        report["totalTokens"] = result.usage.totalTokens
        report["cachedInputTokens"] = result.usage.cachedInputTokens.map { $0 as Any } ?? NSNull()
        report["reasoningOutputTokens"] = result.usage.reasoningOutputTokens.map { $0 as Any } ?? NSNull()
        report["estimatedCostMicroUSD"] = cost.costMicroUSD;report["costBasis"] = cost.costBasis.rawValue
        report["costRateID"] = cost.costRateID;report["cachedInputWasUnknown"] = cost.cachedInputWasUnknown
    } catch let error as MetaResponsesError {
        report["outcome"] = "failed";report["error"] = String(describing:error);exitCode = 1
    } catch {
        report["outcome"] = "failed";report["error"] = "unexpected_answer_or_local_failure";exitCode = 1
    }
    if let wire = await transport.response {
        report["httpStatus"] = wire.status;report["responseBytes"] = wire.body.count
        report["responseSHA256"] = SHA256.hash(data:wire.body).map { String(format:"%02x",$0) }.joined()
        // Shape diagnostics only: no provider identifiers, opaque error bodies or
        // reasoning contents. Whitelists prevent provider values entering logs.
        if let object = try? JSONSerialization.jsonObject(with:wire.body) as? [String:Any] {
            report["responseFields"] = ["id","object","model","status","output","usage","error"].filter { object[$0] != nil }
            report["responseStatus"] = ["completed","incomplete","failed","queued","in_progress"].first { object["status"] as? String == $0 } ?? "unknown"
        }
    }
    try emit(report);return exitCode
}
do { exit(try await run()) }
catch { FileHandle.standardError.write(Data("Meta qualification fixture configuration failed.\n".utf8));exit(2) }
