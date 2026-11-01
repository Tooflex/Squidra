import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Explicit construction only. No environment lookup, global session, retries,
/// cookie jar, credential store or configurable production destination.
public struct MetaHTTPSResponseTransport: MetaResponsesTransport, CustomStringConvertible, CustomDebugStringConvertible {
    private let apiKey: String
    private let protocols: [AnyClass]?
    public var description: String { "MetaHTTPSResponseTransport(credentials: redacted)" }
    public var debugDescription: String { description }
    public init(apiKey: String) throws { try self.init(apiKey:apiKey,protocols:nil) }
    // Internal injection for HTTP protocol tests; not an endpoint override.
    init(apiKey: String, protocols: [AnyClass]?) throws {
        guard (1...4096).contains(apiKey.utf8.count),apiKey.utf8.allSatisfy({
            (48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||[45,46,95,126,43,47,61].contains($0)
        }) else { throw MetaResponsesError.invalidRequest }
        self.apiKey = apiKey;self.protocols = protocols
    }
    public func post(_ body: Data, maximumResponseBytes: Int, deadline: ContinuousClock.Instant) async throws -> MetaHTTPResponse {
        try Task.checkCancellation()
        let now = ContinuousClock.now
        guard !body.isEmpty,body.count <= 131_072,(1...MetaResponsesClient.maximumResponseBytes).contains(maximumResponseBytes) else { throw MetaResponsesError.invalidRequest }
        guard deadline > now,deadline <= now.advanced(by:.seconds(180)) else { throw MetaResponsesError.deadlineExceeded }
        let duration = now.duration(to:deadline).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds)/1e18
        let transfer = MetaResponseTransfer(limit:maximumResponseBytes,deadline:deadline)
        return try await withThrowingTaskGroup(of:MetaHTTPResponse.self) { group in
            group.addTask {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = protocols
                config.urlCache = nil;config.urlCredentialStorage = nil;config.httpCookieStorage = nil
                config.httpShouldSetCookies = false;config.httpCookieAcceptPolicy = .never
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.timeoutIntervalForRequest = seconds;config.timeoutIntervalForResource = seconds
                config.httpMaximumConnectionsPerHost = 1
                var request = URLRequest(url:MetaResponsesClient.endpoint,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:seconds)
                request.httpMethod = "POST";request.httpBody = body;request.httpShouldHandleCookies = false
                request.setValue("Bearer "+apiKey,forHTTPHeaderField:"Authorization")
                request.setValue("application/json",forHTTPHeaderField:"Content-Type")
                request.setValue("application/json",forHTTPHeaderField:"Accept")
                request.setValue("no-store",forHTTPHeaderField:"Cache-Control")
                return try await withTaskCancellationHandler {
                    let response = try await transfer.run(request,configuration:config)
                    try Task.checkCancellation();return response
                } onCancel: { transfer.cancel() }
            }
            group.addTask { try await ContinuousClock().sleep(until:deadline);transfer.cancel(reason:.deadlineExceeded);throw MetaResponsesError.deadlineExceeded }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw MetaResponsesError.transportUnavailable };return response
        }
    }
}

/// URLSession callbacks run on a serial delegate queue. The lock also protects
/// installation/cancellation from the Swift task and deadline racing that queue.
final class MetaResponseTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock(), limit: Int, deadline: ContinuousClock.Instant
    private var continuation: CheckedContinuation<MetaHTTPResponse,any Error>?
    private var task: URLSessionDataTask?
    private var bytes = Data(), response: HTTPURLResponse?
    private var failure: (any Error)?, finished = false
    init(limit: Int, deadline: ContinuousClock.Instant) { self.limit = limit;self.deadline = deadline }
    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> MetaHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            let queue = OperationQueue();queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration:configuration,delegate:self,delegateQueue:queue)
            let task = session.dataTask(with:request)
            let early: (any Error)? = lock.withLock {
                if let failure { finished = true;return failure }
                self.continuation = continuation;self.task = task;return nil
            }
            if let early { session.invalidateAndCancel();continuation.resume(throwing:early) }
            else { task.resume() }
        }
    }
    func cancel(reason: MetaResponsesError? = nil) {
        let task = lock.withLock { () -> URLSessionDataTask? in
            guard !finished else { return nil }
            if failure == nil { failure = reason ?? CancellationError() }
            return self.task
        }
        task?.cancel()
    }
    private func reject(_ error: MetaResponsesError, task: URLSessionTask) {
        lock.withLock { if failure == nil { failure = error } }
        task.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never move a bearer credential or POST body to a redirected URL.
        completionHandler(nil);reject(.rejected,task:task)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition,URLCredential?) -> Void) {
        #if canImport(Security)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling,nil);return
        }
        #endif
        completionHandler(.cancelAuthenticationChallenge,nil);reject(.unauthorized,task:task)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,http.url == MetaResponsesClient.endpoint,ContinuousClock.now < deadline else {
            completionHandler(.cancel);reject(.invalidResponse,task:dataTask);return
        }
        // Error bodies are never needed for typed status mapping, and are not buffered.
        guard http.statusCode == 200 else {
            lock.withLock { self.response = http }
            completionHandler(.cancel);dataTask.cancel();return
        }
        guard http.expectedContentLength <= limit else { completionHandler(.cancel);reject(.invalidResponse,task:dataTask);return }
        let accepted = lock.withLock { () -> Bool in
            guard failure == nil,!finished else { return false };self.response = http;return true
        }
        completionHandler(accepted ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock { () -> Bool in
            guard failure == nil,!finished,response?.statusCode == 200 else { return false }
            guard ContinuousClock.now < deadline else { failure = MetaResponsesError.deadlineExceeded;return true }
            guard data.count <= limit-bytes.count else { failure = MetaResponsesError.invalidResponse;return true }
            bytes.append(data);return false
        }
        if overflow { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let completion = lock.withLock { () -> (CheckedContinuation<MetaHTTPResponse,any Error>,Result<MetaHTTPResponse,any Error>)? in
            guard !finished,let continuation else { return nil }
            finished = true;self.continuation = nil;self.task = nil
            defer { bytes.removeAll(keepingCapacity:false);response = nil }
            if let failure { return (continuation,.failure(failure)) }
            if let response,response.statusCode != 200 {
                return (continuation,.success(MetaHTTPResponse(status:response.statusCode,contentType:"",body:Data())))
            }
            if let error {
                let timeout = (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorTimedOut
                return (continuation,.failure(timeout ? MetaResponsesError.deadlineExceeded : MetaResponsesError.transportUnavailable))
            }
            guard let response,ContinuousClock.now < deadline else { return (continuation,.failure(MetaResponsesError.invalidResponse)) }
            return (continuation,.success(MetaHTTPResponse(status:response.statusCode,contentType:response.value(forHTTPHeaderField:"Content-Type") ?? "",body:bytes)))
        }
        session.finishTasksAndInvalidate()
        if let (continuation,result) = completion { continuation.resume(with:result) }
    }
}
