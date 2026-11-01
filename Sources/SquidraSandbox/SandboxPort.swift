import Foundation

public enum SandboxError: Error, Equatable, Sendable {
    case invalidRequest, denied, unavailable, busy, timedOut, outputLimit, executionFailed, cleanupRequired
}
public enum SandboxNetwork: Sendable { case none, internet }

/// A host allocation; unsupported authority is rejected rather than inherited.
public struct SandboxLimits: Sendable {
    public let memoryMiB: Int, cpuMillis: Int, tasks: Int, workspaceMiB: Int
    public let inputBytes: Int, outputBytes: Int, milliseconds: Int
    public init(memoryMiB: Int = 512, cpuMillis: Int = 1000, tasks: Int = 128, workspaceMiB: Int = 32,
                inputBytes: Int = 65536, outputBytes: Int = 262144, milliseconds: Int = 30000) throws {
        guard (256...512).contains(memoryMiB), (100...1000).contains(cpuMillis), (64...128).contains(tasks),
              (8...32).contains(workspaceMiB), (1...65536).contains(inputBytes),
              (1024...262144).contains(outputBytes), (100...30000).contains(milliseconds) else {
            throw SandboxError.invalidRequest
        }
        self.memoryMiB = memoryMiB; self.cpuMillis = cpuMillis; self.tasks = tasks
        self.workspaceMiB = workspaceMiB; self.inputBytes = inputBytes; self.outputBytes = outputBytes
        self.milliseconds = milliseconds
    }
}

/// Trusted host request, not a decoded model command. Authentication, policy and
/// any required approval belong to the calling gateway. No shell/CLI flags, host
/// mounts, credentials or arbitrary network grants are accepted here.
public struct SandboxRequest: Sendable {
    public let actorID: UUID, runID: UUID, traceID: UUID
    public let html: Data, limits: SandboxLimits
    public let deadline: ContinuousClock.Instant
    public init(actorID: UUID, runID: UUID, traceID: UUID, html: Data, limits: SandboxLimits,
                deadline: ContinuousClock.Instant, network: SandboxNetwork, hostAccess: Bool) throws {
        guard network == .none, !hostAccess else { throw SandboxError.denied }
        guard !html.isEmpty, html.count <= limits.inputBytes, String(data: html, encoding: .utf8) != nil,
              !html.contains(0) else { throw SandboxError.invalidRequest }
        self.actorID = actorID; self.runID = runID; self.traceID = traceID
        self.html = html; self.limits = limits; self.deadline = deadline
    }
}
public struct SandboxResult: Sendable {
    public let actorID: UUID, runID: UUID, traceID: UUID
    public let executionID: UUID
    /// Untrusted rendered DOM, never authority or verified world evidence.
    public let dom: Data
}
public protocol SandboxPort: Sendable {
    func render(_ request: SandboxRequest) async throws -> SandboxResult
}

public struct SandboxCommandResult: Sendable {
    public let status: Int32, stdout: Data
    public init(status: Int32, stdout: Data) { self.status = status; self.stdout = stdout }
}
/// Trusted, injected host driver. Implementations must enforce limits while
/// reading, propagate cancellation, and join the command before returning.
public protocol SandboxCommandRunning: Sendable {
    func run(arguments: [String], input: Data?, deadline: ContinuousClock.Instant,
             maximumOutputBytes: Int) async throws -> SandboxCommandResult
}

/// Private, per-invocation files; no document content is put in argv or logs.
final class SandboxFiles: @unchecked Sendable {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("squidra-sandbox-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }
    func write(_ data: Data, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SandboxError.unavailable
        }
        return url
    }
    func remove() throws { try FileManager.default.removeItem(at: directory) }
}
