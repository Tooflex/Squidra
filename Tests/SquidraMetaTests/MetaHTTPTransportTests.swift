import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SquidraMeta

private final class HTTPScenario: @unchecked Sendable {
    enum Action: Sendable {
        case reply(Int, [String:String], [Data], Bool)
        case redirect
        case failure
    }
    let action: Action
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var stops = 0
    init(_ action: Action) { self.action = action }
    func start(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    func stop() { lock.withLock { stops += 1 } }
    var snapshot: ([URLRequest],Int) { lock.withLock { (requests,stops) } }
}
private final class HTTPScenarios: @unchecked Sendable {
    static let shared = HTTPScenarios()
    private let lock = NSLock()
    private var values: [String:HTTPScenario] = [:]
    func put(_ value: HTTPScenario, key: String) { lock.withLock { values["Bearer " + key] = value } }
    func remove(_ key: String) { _ = lock.withLock { values.removeValue(forKey:"Bearer " + key) } }
    func get(_ request: URLRequest) -> HTTPScenario? { lock.withLock { values[request.value(forHTTPHeaderField:"Authorization") ?? ""] } }
}
private final class OfflineMetaProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true } // Never fall through to a real network.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let scenario = HTTPScenarios.shared.get(request) else {
            client?.urlProtocol(self,didFailWithError:URLError(.badURL));return
        }
        scenario.start(request)
        switch scenario.action {
        case let .reply(status,headers,chunks,finish):
            let response = HTTPURLResponse(url:MetaResponsesClient.endpoint,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers.merging(["Content-Type":"application/json"]) { existing,_ in existing })!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            for chunk in chunks { client?.urlProtocol(self,didLoad:chunk) }
            if finish { client?.urlProtocolDidFinishLoading(self) }
        case .redirect:
            let destination = URL(string:"https://redirect.invalid/private")!
            let response = HTTPURLResponse(url:MetaResponsesClient.endpoint,statusCode:307,httpVersion:"HTTP/1.1",headerFields:["Location":destination.absoluteString])!
            client?.urlProtocol(self,wasRedirectedTo:URLRequest(url:destination),redirectResponse:response)
        case .failure:
            client?.urlProtocol(self,didFailWithError:NSError(domain:"private-error-canary",code:42))
        }
    }
    override func stopLoading() { HTTPScenarios.shared.get(request)?.stop() }
}
final class MetaHTTPTransportTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ action: HTTPScenario.Action) throws -> (MetaHTTPSResponseTransport,HTTPScenario,String) {
        let key = UUID().uuidString, scenario = HTTPScenario(action)
        HTTPScenarios.shared.put(scenario,key:key)
        return (try MetaHTTPSResponseTransport(apiKey:key,protocols:[OfflineMetaProtocol.self]),scenario,key)
    }
    private func post(_ transport: MetaHTTPSResponseTransport, limit: Int = 32, timeout: Duration = .seconds(2)) async throws -> MetaHTTPResponse {
        try await transport.post(Data("{}".utf8),maximumResponseBytes:limit,deadline:.now.advanced(by:timeout))
    }
    private func assertStopped(_ scenario: HTTPScenario, file: StaticString = #filePath, line: UInt = #line) async throws {
        // URLSession terminal delivery and URLProtocol.stopLoading may be scheduled
        // independently. Keep the fixture alive until its cancellation is observed.
        for _ in 0..<250 { if scenario.snapshot.1 > 0 { break };try await Task.sleep(for:.milliseconds(2)) }
        XCTAssertEqual(scenario.snapshot.1,1,file:file,line:line)
    }
    func testFixedAuthenticatedPOSTAndChunkAssembly() async throws {
        let (transport,scenario,key) = try fixture(.reply(200,["Content-Type":"application/json"],[Data("{".utf8),Data("}".utf8)],true))
        defer { HTTPScenarios.shared.remove(key) }
        let response = try await post(transport)
        XCTAssertEqual(response.status,200);XCTAssertEqual(response.body,Data("{}".utf8))
        XCTAssertEqual(response.contentType,"application/json")
        let requests = scenario.snapshot.0;XCTAssertEqual(requests.count,1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url,MetaResponsesClient.endpoint);XCTAssertEqual(request.httpMethod,"POST")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer "+key)
        XCTAssertEqual(request.value(forHTTPHeaderField:"Content-Type"),"application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Accept"),"application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertFalse(String(describing:transport).contains(key));XCTAssertFalse(String(reflecting:transport).contains(key))
    }
    func testErrorStatusDiscardsBodyAndStopsWithoutRetry() async throws {
        for status in [401,403,429,503] {
            let (transport,scenario,key) = try fixture(.reply(status,[:],[Data("private-provider-body".utf8)],false))
            defer { HTTPScenarios.shared.remove(key) }
            let response = try await post(transport)
            XCTAssertEqual(response.status,status);XCTAssertTrue(response.body.isEmpty)
            XCTAssertEqual(scenario.snapshot.0.count,1);try await assertStopped(scenario)
        }
    }
    func testDeclaredAndStreamingOverflowStopDownload() async throws {
        for action: HTTPScenario.Action in [.reply(200,["Content-Length":"33"],[],false),.reply(200,[:],[Data(repeating:65,count:20),Data(repeating:66,count:13)],false)] {
            let (transport,scenario,key) = try fixture(action)
            defer { HTTPScenarios.shared.remove(key) }
            do { _ = try await post(transport);XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.invalidResponse) }
            XCTAssertEqual(scenario.snapshot.0.count,1);try await assertStopped(scenario)
        }
    }
    func testRedirectRefusedWithoutSecondRequest() async throws {
        #if canImport(FoundationNetworking)
        // Corelibs cannot simulate a redirect via URLProtocol. Exercise the same
        // delegate directly, with an unresumed task and no network access.
        let transfer = MetaResponseTransfer(limit:32,deadline:.now.advanced(by:.seconds(2)))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMetaProtocol.self]
        let session = URLSession(configuration:configuration)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url:MetaResponsesClient.endpoint)
        let task = session.dataTask(with:request)
        let redirect = HTTPURLResponse(url:MetaResponsesClient.endpoint,statusCode:307,httpVersion:nil,headerFields:nil)!
        let refused = expectation(description:"redirect refused")
        transfer.urlSession(session,task:task,willPerformHTTPRedirection:redirect,newRequest:request) { next in
            XCTAssertNil(next);refused.fulfill()
        }
        await fulfillment(of:[refused],timeout:1)
        do { _ = try await transfer.run(request,configuration:configuration);XCTFail() }
        catch { XCTAssertEqual(error as? MetaResponsesError,.rejected) }
        #else
        let (transport,scenario,key) = try fixture(.redirect)
        defer { HTTPScenarios.shared.remove(key) }
        do { _ = try await post(transport);XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.rejected) }
        XCTAssertEqual(scenario.snapshot.0.count,1);try await assertStopped(scenario)
        #endif
    }
    func testDeadlineCancelsStalledDownload() async throws {
        let (transport,scenario,key) = try fixture(.reply(200,[:],[],false))
        defer { HTTPScenarios.shared.remove(key) }
        do { _ = try await post(transport,timeout:.milliseconds(500));XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.deadlineExceeded) }
        XCTAssertEqual(scenario.snapshot.0.count,1);try await assertStopped(scenario)
    }
    func testCallerCancellationStopsAndJoinsDownload() async throws {
        let (transport,scenario,key) = try fixture(.reply(200,[:],[],false))
        defer { HTTPScenarios.shared.remove(key) }
        let task = Task { try await self.post(transport) }
        for _ in 0..<200 { if !scenario.snapshot.0.isEmpty { break };try await Task.sleep(for:.milliseconds(2)) }
        XCTAssertEqual(scenario.snapshot.0.count,1);task.cancel()
        do { _ = try await task.value;XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        try await assertStopped(scenario)
    }
    func testInvalidInputNeverStartsAndNetworkErrorsAreSanitized() async throws {
        for key in ["","key\r\nInjected: value","key value","é",String(repeating:"x",count:4097)] {
            XCTAssertThrowsError(try MetaHTTPSResponseTransport(apiKey:key)) { XCTAssertEqual($0 as? MetaResponsesError,.invalidRequest) }
        }
        let (transport,scenario,key) = try fixture(.failure)
        defer { HTTPScenarios.shared.remove(key) }
        for (body,limit) in [(Data(),32),(Data(repeating:1,count:131073),32),(Data([1]),0),(Data([1]),262145)] {
            do { _ = try await transport.post(body,maximumResponseBytes:limit,deadline:.now.advanced(by:.seconds(2)));XCTFail() } catch { XCTAssertEqual(error as? MetaResponsesError,.invalidRequest) }
        }
        XCTAssertTrue(scenario.snapshot.0.isEmpty)
        do { _ = try await post(transport);XCTFail() } catch {
            XCTAssertEqual(error as? MetaResponsesError,.transportUnavailable);XCTAssertFalse(String(describing:error).contains("canary"))
        }
        XCTAssertEqual(scenario.snapshot.0.count,1)
    }
}
