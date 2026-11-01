import Foundation
import XCTest
@testable import SquidraSandbox

private actor DockerFixture: SandboxCommandRunning {
    enum Mode: Sendable { case normal, lostCreate, lostUnobserved, foreign, timeout, cancelled, outputLimit, wrongOS, slow }
    let mode: Mode
    var calls: [[String]] = [], received: Data?, exists = false, owner = "", removed = false
    let id = String(repeating: "a", count: 64)
    init(_ mode: Mode = .normal) { self.mode = mode }
    func run(arguments a: [String], input: Data?, deadline: ContinuousClock.Instant, maximumOutputBytes: Int) async throws -> SandboxCommandResult {
        calls.append(a)
        var text = ""
        switch a.first {
        case "version": text = mode == .wrongOS ? "linux/amd64" : "linux/arm64"
        case "image": text = "sha256:" + String(repeating: "b", count: 64)
        case "create":
            owner = a.first(where: { $0.hasPrefix("io.squidra.sandbox.owner=") })!.split(separator: "=").last.map(String.init)!
            exists = true
            if mode == .lostCreate { throw SandboxError.unavailable }
            if mode == .lostUnobserved { exists = false; throw SandboxError.unavailable }
            text = id
        case "inspect":
            text = "{\"id\":\"\(id)\",\"owner\":\"\(mode == .foreign ? "foreign" : owner)\",\"running\":false,\"exitCode\":0}"
        case "start":
            received = input
            if mode == .slow { try await Task.sleep(for: .milliseconds(150)) }
            switch mode {
            case .timeout: throw SandboxError.timedOut
            case .cancelled: throw CancellationError()
            case .outputLimit: throw SandboxError.outputLimit
            default: text = "<p>rendered</p>"
            }
        case "ps":
            XCTAssertFalse(Task.isCancelled, "Cleanup must not inherit caller cancellation")
            text = exists ? id : ""
        case "rm":
            XCTAssertEqual(a.last, id); XCTAssertEqual(a, ["rm", "--force", id])
            exists = false; removed = true
        default: throw SandboxError.unavailable
        }
        return SandboxCommandResult(status: 0, stdout: Data(text.utf8))
    }
}

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private func configuration(image: String = "sha256:" + String(repeating: "b", count: 64), executable: String = "/usr/bin/docker", socket: String = "/tmp/docker.sock") throws -> DockerSandboxConfiguration {
    try DockerSandboxConfiguration(executable: URL(fileURLWithPath: executable), socket: URL(fileURLWithPath: socket),
        imageID: image, seccompProfile: Data(contentsOf: root.appendingPathComponent("Scripts/sandbox/seccomp.json")))
}
private func request(html: String = "<p>PRIVATE_DOCUMENT</p>", limits: SandboxLimits = try! SandboxLimits(),
                     runID: UUID = UUID()) throws -> SandboxRequest {
    try SandboxRequest(actorID: UUID(), runID: runID, traceID: UUID(), html: Data(html.utf8), limits: limits,
        deadline: .now.advanced(by: .seconds(30)), network: .none, hostAccess: false)
}

final class SandboxTests: XCTestCase, @unchecked Sendable {
    func testTypedRequestsRejectUnsupportedAuthorityAndQuotaViolations() throws {
        let b = try SandboxLimits(), id = UUID()
        for (network, host) in [(SandboxNetwork.internet, false), (.none, true)] {
            XCTAssertThrowsError(try SandboxRequest(actorID: id, runID: id, traceID: id, html: Data("x".utf8),
                limits: b, deadline: .now, network: network, hostAccess: host)) { XCTAssertEqual($0 as? SandboxError, .denied) }
        }
        for data in [Data(), Data([255]), Data([0]), Data(repeating: 65, count: 65537)] {
            XCTAssertThrowsError(try SandboxRequest(actorID: id, runID: id, traceID: id, html: data,
                limits: b, deadline: .now, network: .none, hostAccess: false))
        }
        XCTAssertThrowsError(try SandboxLimits(memoryMiB: 513))
        XCTAssertThrowsError(try SandboxLimits(cpuMillis: 1001))
        XCTAssertThrowsError(try SandboxLimits(tasks: 129))
        XCTAssertThrowsError(try SandboxLimits(workspaceMiB: 33))
        XCTAssertThrowsError(try SandboxLimits(outputBytes: 262145))
        XCTAssertThrowsError(try SandboxLimits(milliseconds: 30001))
        XCTAssertThrowsError(try configuration(image: "mutable:latest"))
        XCTAssertThrowsError(try DockerSandboxConfiguration(executable: URL(fileURLWithPath: "/usr/bin/docker"),
            socket: URL(fileURLWithPath: "/tmp/docker.sock"), imageID: "sha256:" + String(repeating: "b", count: 64), seccompProfile: Data("{}".utf8)))
    }

    func testRenderingUsesStdinFixedAuthorityAndCorrelatedResultThenCleanup() async throws {
        let fixture = DockerFixture(), req = try request()
        let result = try await DockerBrowserSandbox(configuration: configuration(), driver: fixture).render(req)
        XCTAssertEqual(result.actorID, req.actorID); XCTAssertEqual(result.runID, req.runID); XCTAssertEqual(result.traceID, req.traceID)
        XCTAssertEqual(String(decoding: result.dom, as: UTF8.self), "<p>rendered</p>")
        let received = await fixture.received, calls = await fixture.calls, removed = await fixture.removed
        XCTAssertEqual(received, req.html); XCTAssertTrue(removed)
        XCTAssertFalse(calls.flatMap { $0 }.joined().contains("PRIVATE_DOCUMENT"))
        let create = try XCTUnwrap(calls.first(where: { $0.first == "create" }))
        for argument in ["--pull", "never", "--network", "none", "--read-only", "--cap-drop", "ALL", "no-new-privileges", "--log-driver", "512m", "128"] {
            XCTAssertTrue(create.contains(argument))
        }
        XCTAssertFalse(create.contains("--privileged")); XCTAssertFalse(create.contains("--volume"))
        XCTAssertTrue(create.contains("io.squidra.sandbox.run=" + req.runID.uuidString.lowercased()))
        XCTAssertEqual(create.last, "sha256:" + String(repeating: "b", count: 64))
    }

    func testLostCreateAcknowledgementReconcilesExactNameAndCleans() async throws {
        let fixture = DockerFixture(.lostCreate)
        do { _ = try await DockerBrowserSandbox(configuration: configuration(), driver: fixture).render(request()); XCTFail("lost acknowledgement") }
        catch { XCTAssertEqual(error as? SandboxError, .unavailable) }
        let removed = await fixture.removed, calls = await fixture.calls
        XCTAssertTrue(removed); XCTAssertFalse(calls.contains(where: { $0.first == "start" }))
        let filter = try XCTUnwrap(calls.first(where: { $0.first == "ps" }))
        XCTAssertTrue(filter.contains(where: { $0.hasPrefix("name=^/squidra-sandbox-") && $0.hasSuffix("$") }))
    }

    func testUnobservedCreateCannotBeMistakenForConfirmedCleanup() async throws {
        let fixture = DockerFixture(.lostUnobserved), port = DockerBrowserSandbox(configuration: try configuration(), driver: fixture)
        do { _ = try await port.render(request()); XCTFail("Late create cannot be excluded") }
        catch { XCTAssertEqual(error as? SandboxError, .cleanupRequired) }
        do { _ = try await port.render(request()); XCTFail("Unknown resource released capacity") }
        catch { XCTAssertEqual(error as? SandboxError, .busy) }
        let calls = await fixture.calls; XCTAssertFalse(calls.contains { ["start", "rm"].contains($0.first ?? "") })
    }

    func testForeignOwnershipRefusesDestructionAndReportsCleanupRequired() async throws {
        let fixture = DockerFixture(.foreign)
        let port = DockerBrowserSandbox(configuration: try configuration(), driver: fixture)
        do { _ = try await port.render(request()); XCTFail("foreign owner") }
        catch { XCTAssertEqual(error as? SandboxError, .cleanupRequired) }
        do { _ = try await port.render(request()); XCTFail("Uncertain cleanup released capacity") }
        catch { XCTAssertEqual(error as? SandboxError, .busy) }
        let calls = await fixture.calls
        XCTAssertFalse(calls.contains(where: { ["start", "rm"].contains($0.first ?? "") }))
    }

    func testConcurrentAdmissionIsBoundedAndSuccessfulCleanupReleasesCapacity() async throws {
        let fixture = DockerFixture(.slow), port = DockerBrowserSandbox(configuration: try configuration(), driver: fixture)
        let first = Task { try await port.render(request()) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await fixture.received == nil, ContinuousClock.now < deadline { await Task.yield() }
        do { _ = try await port.render(request()); XCTFail("Concurrent render admitted") }
        catch { XCTAssertEqual(error as? SandboxError, .busy) }
        _ = try await first.value
        _ = try await port.render(request())
        let calls = await fixture.calls.filter { $0.first == "start" }; XCTAssertEqual(calls.count, 2)
    }

    func testFailureTimeoutOutputLimitAndCancellationAllJoinCleanup() async throws {
        for mode in [DockerFixture.Mode.timeout, .cancelled, .outputLimit] {
            let fixture = DockerFixture(mode)
            do { _ = try await DockerBrowserSandbox(configuration: configuration(), driver: fixture).render(request()); XCTFail("expected failure") }
            catch {
                if mode == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? SandboxError, mode == .timeout ? .timedOut : .outputLimit) }
            }
            let removed = await fixture.removed; XCTAssertTrue(removed)
        }
        let fixture = DockerFixture(.wrongOS)
        do { _ = try await DockerBrowserSandbox(configuration: configuration(), driver: fixture).render(request()); XCTFail("unqualified OS") }
        catch { XCTAssertEqual(error as? SandboxError, .unavailable) }
        let calls = await fixture.calls; XCTAssertEqual(calls.count, 1)
    }

    func testBoundedDriverStdinAndEnvironmentDoNotInheritSecrets() async throws {
        let cat = try BoundedSandboxCommand(executable: URL(fileURLWithPath: "/bin/cat"), environment: [:])
        let content = Data("PRIVATE_INPUT".utf8)
        let result = try await cat.run(arguments: [], input: content, deadline: .now.advanced(by: .seconds(2)), maximumOutputBytes: 100)
        XCTAssertEqual(result.stdout, content); XCTAssertEqual(result.status, 0)
        let env = try BoundedSandboxCommand(executable: URL(fileURLWithPath: "/usr/bin/env"), environment: ["ONLY_FIXTURE": "yes"])
        let observed = try await env.run(arguments: [], input: nil, deadline: .now.advanced(by: .seconds(2)), maximumOutputBytes: 100)
        XCTAssertEqual(String(decoding: observed.stdout, as: UTF8.self), "ONLY_FIXTURE=yes\n")
    }

    func testExpiredAndCancelledRequestsNeverCreateResources() async throws {
        let fixture = DockerFixture(), port = DockerBrowserSandbox(configuration: try configuration(), driver: fixture)
        let expired = try SandboxRequest(actorID: UUID(), runID: UUID(), traceID: UUID(), html: Data("x".utf8),
            limits: SandboxLimits(), deadline: .now.advanced(by: .seconds(-1)), network: .none, hostAccess: false)
        do { _ = try await port.render(expired); XCTFail("expired") }
        catch { XCTAssertEqual(error as? SandboxError, .timedOut) }
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await port.render(request())
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let calls = await fixture.calls; XCTAssertTrue(calls.isEmpty)
        let missing = try BoundedSandboxCommand(executable: URL(fileURLWithPath: "/nonexistent/squidra"), environment: [:])
        do { _ = try await missing.run(arguments: [], input: nil, deadline: .now.advanced(by: .seconds(2)), maximumOutputBytes: 1024); XCTFail("missing binary") }
        catch { XCTAssertEqual(error as? SandboxError, .unavailable) }
    }

    func testBoundedDriverKillsAndJoinsOverflowTimeoutAndCancellation() async throws {
        let yes = try BoundedSandboxCommand(executable: URL(fileURLWithPath: "/usr/bin/yes"), environment: [:])
        do { _ = try await yes.run(arguments: [], input: nil, deadline: .now.advanced(by: .seconds(2)), maximumOutputBytes: 1024); XCTFail("overflow") }
        catch { XCTAssertEqual(error as? SandboxError, .outputLimit) }
        let sleep = try BoundedSandboxCommand(executable: URL(fileURLWithPath: "/bin/sleep"), environment: [:])
        do { _ = try await sleep.run(arguments: ["10"], input: nil, deadline: .now.advanced(by: .milliseconds(100)), maximumOutputBytes: 1024); XCTFail("timeout") }
        catch { XCTAssertEqual(error as? SandboxError, .timedOut) }
        let task = Task { try await sleep.run(arguments: ["10"], input: nil, deadline: .now.advanced(by: .seconds(10)), maximumOutputBytes: 1024) }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        do { _ = try await task.value; XCTFail("cancel") } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private actor LostCreateAcknowledgement: SandboxCommandRunning {
    let driver: BoundedSandboxCommand
    var starts = 0
    init(driver: BoundedSandboxCommand) { self.driver = driver }
    func run(arguments: [String], input: Data?, deadline: ContinuousClock.Instant, maximumOutputBytes: Int) async throws -> SandboxCommandResult {
        if arguments.first == "start" { starts += 1 }
        let result = try await driver.run(arguments: arguments, input: input, deadline: deadline, maximumOutputBytes: maximumOutputBytes)
        if arguments.first == "create", result.status == 0 { throw SandboxError.unavailable }
        return result
    }
}

final class SandboxLiveTests: XCTestCase, @unchecked Sendable {
    private func live() throws -> (DockerBrowserSandbox, BoundedSandboxCommand) {
        let env = ProcessInfo.processInfo.environment
        guard env["SQUIDRA_SANDBOX_LIVE"] == "1", let image = env["SQUIDRA_SANDBOX_IMAGE"],
              let exe = env["SQUIDRA_SANDBOX_DOCKER"], let socket = env["SQUIDRA_SANDBOX_SOCKET"] else {
            throw SandboxError.unavailable // explicit runner required, no silent skip
        }
        let config = try configuration(image: image, executable: exe, socket: socket)
        return (try DockerBrowserSandbox(configuration: config),
                try BoundedSandboxCommand(executable: config.executable, environment: [
                    "DOCKER_HOST": "unix://" + socket, "DOCKER_CONFIG": "/nonexistent", "HOME": "/nonexistent", "PATH": "/usr/bin:/bin",
                ]))
    }
    private func containers(_ run: UUID, driver: BoundedSandboxCommand, running: Bool = false) async throws -> String {
        var args = ["ps", "--all", "--filter", "label=io.squidra.sandbox.run=" + run.uuidString.lowercased(), "--format", "{{.ID}}"]
        if running { args += ["--filter", "status=running"] }
        let result = try await driver.run(arguments: args, input: nil, deadline: .now.advanced(by: .seconds(3)), maximumOutputBytes: 4096)
        XCTAssertEqual(result.status, 0)
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func testRealBrowserRendersStdinAndDestroysWorkspace() async throws {
        let (port, driver) = try live()
        let req = try request(html: "<p id='result'>before</p><script>document.getElementById('result').textContent='SWIFT_BROWSER_OK'</script>")
        let result = try await port.render(req)
        XCTAssertTrue(String(decoding: result.dom, as: UTF8.self).contains("<p id=\"result\">SWIFT_BROWSER_OK</p>"))
        XCTAssertEqual(result.actorID, req.actorID); XCTAssertEqual(result.runID, req.runID); XCTAssertEqual(result.traceID, req.traceID)
        let remaining = try await containers(req.runID, driver: driver); XCTAssertEqual(remaining, "")
    }
    func testRealLostCreateAcknowledgementFindsExactOwnedNameAndRemovesIt() async throws {
        let (_, driver) = try live(), env = ProcessInfo.processInfo.environment
        let config = try configuration(image: env["SQUIDRA_SANDBOX_IMAGE"]!, executable: env["SQUIDRA_SANDBOX_DOCKER"]!, socket: env["SQUIDRA_SANDBOX_SOCKET"]!)
        let lost = LostCreateAcknowledgement(driver: driver)
        let port = DockerBrowserSandbox(configuration: config, driver: lost), req = try request()
        do { _ = try await port.render(req); XCTFail("Lost acknowledgement returned success") }
        catch { XCTAssertEqual(error as? SandboxError, .unavailable) }
        let remaining = try await containers(req.runID, driver: driver), starts = await lost.starts
        XCTAssertEqual(remaining, ""); XCTAssertEqual(starts, 0)
    }
    func testRealOutputOverflowAndDeadlineLeaveNoOwnedContainer() async throws {
        let (port, driver) = try live()
        let big = try request(html: "<script>document.write('x'.repeat(500000))</script>", limits: SandboxLimits(outputBytes: 1024))
        do { _ = try await port.render(big); XCTFail("output limit") } catch { XCTAssertEqual(error as? SandboxError, .outputLimit) }
        let first = try await containers(big.runID, driver: driver); XCTAssertEqual(first, "")
        let forever = try request(html: "<script>while(true){}</script>", limits: SandboxLimits(milliseconds: 2000))
        do { _ = try await port.render(forever); XCTFail("deadline") } catch { XCTAssertEqual(error as? SandboxError, .timedOut) }
        let second = try await containers(forever.runID, driver: driver); XCTAssertEqual(second, "")
    }
    func testRealRunningBrowserCancellationJoinsOwnedDestruction() async throws {
        let (port, driver) = try live(), req = try request(html: "<script>while(true){}</script>")
        let task = Task { try await port.render(req) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var running = false
        do {
            while ContinuousClock.now < deadline {
                if try await !containers(req.runID, driver: driver, running: true).isEmpty { running = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch { task.cancel(); _ = try? await task.value; throw error }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled execution returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(running, "Cancellation must target a genuinely running browser container")
        let remaining = try await containers(req.runID, driver: driver); XCTAssertEqual(remaining, "")
    }
}
