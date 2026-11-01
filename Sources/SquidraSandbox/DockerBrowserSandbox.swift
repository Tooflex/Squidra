import Crypto
import Foundation

public struct DockerSandboxConfiguration: Sendable {
    public static let profileSHA256 = "e53c15d248f57bceec0a3a16fad1b4ab0d05a7bddb455f86a60e2dba5612cdf7"
    public let executable: URL, socket: URL, imageID: String
    let profile: Data
    public init(executable: URL, socket: URL, imageID: String, seccompProfile: Data) throws {
        guard executable.isFileURL, socket.isFileURL, executable.path.hasPrefix("/"), socket.path.hasPrefix("/"),
              !socket.path.contains("\0"), !socket.path.contains("\n"),
              imageID.hasPrefix("sha256:"), Self.hex(String(imageID.dropFirst(7))), seccompProfile.count <= 65536,
              SHA256.hash(data: seccompProfile).map({ String(format: "%02x", $0) }).joined() == Self.profileSHA256 else {
            throw SandboxError.invalidRequest
        }
        self.executable = executable; self.socket = socket; self.imageID = imageID; profile = seccompProfile
    }
    static func hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// First verified engine: offline Chromium in a Linux arm64 Docker container.
/// Configuration is trusted host authority. It must identify the reviewed image,
/// local daemon socket and seccomp profile, never values proposed by a model.
public struct DockerBrowserSandbox: SandboxPort {
    private let configuration: DockerSandboxConfiguration
    private let driver: any SandboxCommandRunning
    private let admission = SandboxAdmission()
    public init(configuration: DockerSandboxConfiguration) throws {
        self.configuration = configuration
        driver = try BoundedSandboxCommand(executable: configuration.executable, environment: [
            "DOCKER_HOST": "unix://" + configuration.socket.path,
            "DOCKER_CONFIG": "/nonexistent", "HOME": "/nonexistent", "PATH": "/usr/bin:/bin", "LANG": "C",
        ])
    }
    /// Injection is a host/test seam, not a client-selectable executor.
    public init(configuration: DockerSandboxConfiguration, driver: any SandboxCommandRunning) {
        self.configuration = configuration; self.driver = driver
    }
    private struct Inspection: Decodable {
        let id: String, owner: String, running: Bool, exitCode: Int32
    }
    private static let inspectFormat = #"{"id":{{json .Id}},"owner":{{json (index .Config.Labels "io.squidra.sandbox.owner")}},"running":{{json .State.Running}},"exitCode":{{json .State.ExitCode}}}"#

    public func render(_ request: SandboxRequest) async throws -> SandboxResult {
        try await admission.acquire()
        do {
            let result = try await perform(request)
            await admission.release()
            return result
        } catch {
            // Retain the slot when a resource may still exist. Do not turn a
            // daemon outage into an unbounded sequence of orphan containers.
            if error as? SandboxError != .cleanupRequired { await admission.release() }
            if error is CancellationError { throw CancellationError() }
            throw (error as? SandboxError) ?? SandboxError.unavailable
        }
    }
    private func perform(_ request: SandboxRequest) async throws -> SandboxResult {
        try Task.checkCancellation()
        let deadline = min(request.deadline, .now.advanced(by: .milliseconds(request.limits.milliseconds)))
        guard ContinuousClock.now < deadline else { throw SandboxError.timedOut }
        let files = try SandboxFiles(), executionID = UUID()
        let name = "squidra-sandbox-" + executionID.uuidString.lowercased(), owner = UUID().uuidString.lowercased()
        var container: String?, createAttempted = false
        let outcome: Result<Data, Error>
        do {
            let profile = try files.write(configuration.profile, name: "seccomp.json")
            let server = try await command(["version", "--format", "{{.Server.Os}}/{{.Server.Arch}}"], deadline: deadline)
            guard Self.text(server) == "linux/arm64" else { throw SandboxError.unavailable }
            let image = try await command(["image", "inspect", "--format", "{{.Id}}", configuration.imageID], deadline: deadline)
            guard Self.text(image) == configuration.imageID else { throw SandboxError.unavailable }
            let b = request.limits
            let args = ["create", "--pull", "never", "--interactive", "--name", name,
                "--label", "io.squidra.sandbox.owner=" + owner,
                "--label", "io.squidra.sandbox.run=" + request.runID.uuidString.lowercased(),
                "--label", "io.squidra.sandbox.actor=" + request.actorID.uuidString.lowercased(),
                "--network", "none", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                "--security-opt", "seccomp=" + profile.path, "--user", "1000:1000",
                "--pids-limit", String(b.tasks), "--memory", "\(b.memoryMiB)m", "--memory-swap", "\(b.memoryMiB)m",
                "--cpus", String(Double(b.cpuMillis) / 1000), "--shm-size", "64m", "--ulimit", "nofile=1024:1024",
                "--log-driver", "none", "--workdir", "/work", "--env", "HOME=/work",
                "--tmpfs", "/work:rw,nosuid,nodev,size=\(b.workspaceMiB)m,uid=1000,gid=1000,mode=700",
                "--tmpfs", "/tmp:rw,nosuid,nodev,size=64m,mode=1777",
                "--entrypoint", "/usr/local/bin/squidra-browser", configuration.imageID]
            // Set before I/O: a failed/cancelled create may have committed.
            createAttempted = true
            let created = Self.text(try await command(args, deadline: deadline))
            guard DockerSandboxConfiguration.hex(created) else { throw SandboxError.unavailable }
            container = created
            let before = try await inspect(created, deadline: deadline)
            guard before.id == created, before.owner == owner, !before.running else { throw SandboxError.denied }
            let rendered = try await driver.run(arguments: ["start", "--attach", "--interactive", created],
                input: request.html, deadline: deadline, maximumOutputBytes: b.outputBytes)
            try Task.checkCancellation()
            let after = try await inspect(created, deadline: deadline)
            guard rendered.status == 0, after.id == created, after.owner == owner,
                  !after.running, after.exitCode == 0, !rendered.stdout.isEmpty,
                  rendered.stdout.count <= b.outputBytes, String(data: rendered.stdout, encoding: .utf8) != nil else {
                throw SandboxError.executionFailed
            }
            outcome = .success(rendered.stdout)
        } catch { outcome = .failure(error) }

        // Cancellation of the caller must not cancel cleanup. This detached task
        // is always joined and has its own fixed ten-second deadline. A lost
        // acknowledgement is not reported as a successful cleanup.
        var cleanupFailed = false
        if createAttempted {
            let known = container
            do { try await Task.detached { try await cleanup(known: known, name: name, owner: owner) }.value }
            catch { cleanupFailed = true }
        }
        do { try files.remove() } catch { cleanupFailed = true }
        guard !cleanupFailed else { throw SandboxError.cleanupRequired }
        try Task.checkCancellation()
        let dom = try outcome.get()
        guard ContinuousClock.now < deadline else { throw SandboxError.timedOut }
        return SandboxResult(actorID: request.actorID, runID: request.runID, traceID: request.traceID,
                             executionID: executionID, dom: dom)
    }

    private func command(_ args: [String], deadline: ContinuousClock.Instant) async throws -> Data {
        let result = try await driver.run(arguments: args, input: nil, deadline: deadline, maximumOutputBytes: 8192)
        guard result.status == 0 else { throw SandboxError.unavailable }
        return result.stdout
    }
    private func inspect(_ id: String, deadline: ContinuousClock.Instant) async throws -> Inspection {
        do { return try JSONDecoder().decode(Inspection.self, from: await command(["inspect", "--format", Self.inspectFormat, id], deadline: deadline)) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SandboxError.unavailable }
    }
    private func cleanup(known: String?, name: String, owner: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        let filter = known.map { "id=" + $0 } ?? "name=^/" + name + "$"
        let listed = Self.text(try await command(["ps", "--all", "--no-trunc", "--filter", filter, "--format", "{{.ID}}"], deadline: deadline))
        if listed.isEmpty {
            // After an unacknowledged create, absence now does not exclude a
            // late daemon commit. Retain admission and require reconciliation.
            guard known != nil else { throw SandboxError.cleanupRequired }
            return
        }
        guard DockerSandboxConfiguration.hex(listed), known == nil || known == listed else { throw SandboxError.cleanupRequired }
        let record = try await inspect(listed, deadline: deadline)
        guard record.id == listed, record.owner == owner else { throw SandboxError.cleanupRequired }
        _ = try await command(["rm", "--force", listed], deadline: deadline)
        let remaining = Self.text(try await command(["ps", "--all", "--no-trunc", "--filter", "id=" + listed, "--format", "{{.ID}}"], deadline: deadline))
        guard remaining.isEmpty else { throw SandboxError.cleanupRequired }
    }
    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One active execution per shared host adapter, with no unbounded wait queue.
private actor SandboxAdmission {
    private var active = false
    func acquire() throws {
        try Task.checkCancellation()
        guard !active else { throw SandboxError.busy }
        active = true
    }
    func release() { active = false }
}
