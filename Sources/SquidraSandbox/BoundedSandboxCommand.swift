import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Executes one explicitly configured host binary, never a shell. Environment is
/// supplied by the trusted host, not inherited from the process or a request.
public struct BoundedSandboxCommand: SandboxCommandRunning {
    private let executable: URL, environment: [String: String]
    public init(executable: URL, environment: [String: String]) throws {
        guard executable.isFileURL, executable.path.hasPrefix("/"), !executable.path.contains("\0") else {
            throw SandboxError.invalidRequest
        }
        self.executable = executable; self.environment = environment
    }
    public func run(arguments: [String], input: Data?, deadline: ContinuousClock.Instant,
                    maximumOutputBytes: Int) async throws -> SandboxCommandResult {
        let now = ContinuousClock.now
        guard deadline > now else { throw SandboxError.timedOut }
        guard deadline <= now.advanced(by: .seconds(30)) else { throw SandboxError.invalidRequest }
        guard (1...1_048_576).contains(maximumOutputBytes), (input?.count ?? 0) <= 65536,
              arguments.count <= 128, arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 }) else {
            throw SandboxError.invalidRequest
        }
        let command = RunningCommand(executable: executable, environment: environment, arguments: arguments,
                                     input: input, deadline: deadline, limit: maximumOutputBytes)
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await Task.detached { try command.execute() }.value
            } onCancel: { command.stop(cancelled: true) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as SandboxError { throw error }
        catch { throw SandboxError.unavailable }
    }
}

/// All mutable state is protected by lock. Reader tasks only access their own
/// file handle; process lifecycle is joined before the invocation completes.
private final class RunningCommand: @unchecked Sendable {
    let lock = NSLock(), process = Process()
    let input: Data?, deadline: ContinuousClock.Instant, limit: Int
    var cancelled = false, failure: SandboxError?, finished = false
    var stdout = Data(), stderrBytes = 0
    init(executable: URL, environment: [String: String], arguments: [String], input: Data?,
         deadline: ContinuousClock.Instant, limit: Int) {
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        self.input = input; self.deadline = deadline; self.limit = limit
    }
    func stop(cancelled: Bool = false, failure: SandboxError? = nil) {
        lock.withLock {
            guard !finished else { return }
            self.cancelled = self.cancelled || cancelled
            if self.failure == nil { self.failure = failure }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }
    func execute() throws -> SandboxCommandResult {
        let files = try SandboxFiles()
        let outcome: Result<SandboxCommandResult, Error>
        do { outcome = .success(try execute(files: files)) }
        catch { outcome = .failure(error) }
        do { try files.remove() } catch { throw SandboxError.cleanupRequired }
        return try outcome.get()
    }
    private func execute(files: SandboxFiles) throws -> SandboxCommandResult {
        let inputHandle: FileHandle
        if let input { inputHandle = try FileHandle(forReadingFrom: files.write(input, name: "input")) }
        else { inputHandle = FileHandle.nullDevice }
        defer { try? inputHandle.close() }
        let output = Pipe(), errors = Pipe()
        process.standardInput = inputHandle; process.standardOutput = output; process.standardError = errors
        try lock.withLock {
            if cancelled { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw SandboxError.timedOut }
            do { try process.run() } catch { throw SandboxError.unavailable }
        }
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        let readers = DispatchGroup()
        for (handle, isOutput) in [(output.fileHandleForReading, true), (errors.fileHandleForReading, false)] {
            readers.enter()
            DispatchQueue.global().async { [self] in
                defer { try? handle.close(); readers.leave() }
                do {
                    while let chunk = try handle.read(upToCount: 8192), !chunk.isEmpty {
                        let overflow = lock.withLock {
                            if isOutput {
                                guard chunk.count <= limit - stdout.count else { return true }
                                stdout.append(chunk)
                            } else {
                                guard chunk.count <= 16384 - stderrBytes else { return true }
                                stderrBytes += chunk.count // discarded, never logged or returned
                            }
                            return false
                        }
                        if overflow { stop(failure: .outputLimit); return }
                    }
                } catch { stop(failure: .unavailable) }
            }
        }
        let duration = ContinuousClock.now.duration(to: deadline).components
        let seconds = max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        let timer = DispatchWorkItem { [self] in stop(failure: .timedOut) }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
        process.waitUntilExit()
        timer.cancel()
        // The fixed binary must not daemonize while retaining our pipes. Docker
        // commands used by the adapter do not pass these handles to containers.
        readers.wait()
        return try lock.withLock {
            finished = true
            if cancelled { throw CancellationError() }
            if let failure { throw failure }
            guard ContinuousClock.now < deadline else { throw SandboxError.timedOut }
            return SandboxCommandResult(status: process.terminationStatus, stdout: stdout)
        }
    }
}
