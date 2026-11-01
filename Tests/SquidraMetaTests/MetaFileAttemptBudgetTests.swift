import Foundation
import SquidraCognition
import SquidraDomain
import XCTest
@testable import SquidraMeta
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class MetaFileAttemptBudgetTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("squidra-budget-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        addTeardownBlock { try FileManager.default.removeItem(at:url) };return url
    }
    private func initial() -> [String:Any] {
        ["schemaVersion":1,"authorizedEURCents":10000,"reservationEURCents":1000,
         "fx":["usdPerEUR":"1.1172","date":"2026-10-30","source":"ECB"],"validUntil":"2026-11-02T00:00:00+00:00","attempts":[[String:Any]]()]
    }
    private func save(_ value: [String:Any], to directory: URL) throws {
        let url = directory.appendingPathComponent("live-budget.json")
        try JSONSerialization.data(withJSONObject:value).write(to:url)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private func load(_ directory: URL) throws -> [String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("live-budget.json"))) as? [String:Any])
    }
    private func budget(_ directory: URL, now: Double = 1_793_500_000) throws -> MetaFileAttemptBudget {
        try MetaFileAttemptBudget(directory:directory,clock:FixedClock(instant:UTCInstant(secondsSince1970:now),timeZone:IANATimeZone(identifier:"UTC")))
    }
    private func reserve(_ budget: MetaFileAttemptBudget, id: UUID = UUID(), amount: Int64 = 10_000_000, deadline: ContinuousClock.Instant = .now.advanced(by:.seconds(3))) async throws {
        try await budget.reserve(attemptID:id,requestID:UUID(),model:.spark,maximumCostMicroUSD:amount,deadline:deadline)
    }
    func testRestartAndExhaustionPreserveEarlierSAMReportsAndFailedReservations() async throws {
        let dir = try directory();var value = initial()
        let old: [String:Any] = ["id":UUID().uuidString.lowercased(),"model":"sam-3.1","reservedEURCents":1000,"status":"failed","report":["outcome":"failed","observed":true]]
        value["attempts"] = [old];try save(value,to:dir)
        for _ in 0..<9 { try await reserve(budget(dir)) }
        do { try await reserve(budget(dir));XCTFail() } catch { XCTAssertEqual(error as? ModelRoutingError,.budgetExceeded) }
        let attempts = try XCTUnwrap(load(dir)["attempts"] as? [[String:Any]])
        XCTAssertEqual(attempts.count,10);XCTAssertEqual(attempts.first? ["id"] as? String,old["id"] as? String)
        XCTAssertEqual((attempts[0]["report"] as? [String:Any])?["observed"] as? Bool,true)
        XCTAssertTrue(attempts.dropFirst().allSatisfy { $0["status"] as? String == "reserved" && $0["report"] is NSNull })
    }
    func testDuplicateIdentityAndOversizedReservationCannotDispatch() async throws {
        let dir = try directory();try save(initial(),to:dir);let id = UUID(),ledger = try budget(dir)
        try await reserve(ledger,id:id)
        for (attempt,amount) in [(id,Int64(10_000_000)),(UUID(),11_172_001),(UUID(),0)] {
            do { try await reserve(ledger,id:attempt,amount:amount);XCTFail() } catch { XCTAssertEqual(error as? MetaBudgetError,.invalidReservation) }
        }
        XCTAssertEqual((try load(dir)["attempts"] as? [Any])?.count,1)
    }
    func testMissingInsecureAndSymlinkStateNeverInitializesBudget() async throws {
        let dir = try directory(),ledger = try budget(dir)
        do { try await reserve(ledger);XCTFail() } catch { XCTAssertEqual(error as? MetaBudgetError,.unsafePath) }
        try save(initial(),to:dir)
        let path = dir.appendingPathComponent("live-budget.json")
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:path.path)
        do { try await reserve(ledger);XCTFail() } catch { XCTAssertEqual(error as? MetaBudgetError,.unsafePath) }
        try FileManager.default.moveItem(at:path,to:dir.appendingPathComponent("actual.json"))
        try FileManager.default.createSymbolicLink(atPath:path.path,withDestinationPath:"actual.json")
        do { try await reserve(ledger);XCTFail() } catch { XCTAssertEqual(error as? MetaBudgetError,.unsafePath) }
        try FileManager.default.removeItem(at:path)
        XCTAssertEqual(mkfifo(path.path,mode_t(0o600)),0)
        do { try await reserve(ledger);XCTFail() } catch { XCTAssertEqual(error as? MetaBudgetError,.unsafePath) }
        try FileManager.default.removeItem(at:path);try save(initial(),to:dir)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:dir.path)
        do { try await reserve(ledger);XCTFail() } catch { XCTAssertEqual(error as? MetaBudgetError,.unsafePath) }
    }
    func testCorruptCapTypesMetadataAndDuplicateJSONKeysFailClosed() async throws {
        let dir = try directory(),ledger = try budget(dir)
        var variants: [[String:Any]] = []
        for (key,value) in [("schemaVersion",true as Any),("authorizedEURCents",20000 as Any),("reservationEURCents",0 as Any),("validUntil","2099-01-01" as Any),("fx",["usdPerEUR":"2"] as Any)] {
            var item = initial();item[key] = value;variants.append(item)
        }
        for item in variants {
            try save(item,to:dir)
            do { try await reserve(ledger);XCTFail() } catch { XCTAssertEqual(error as? MetaBudgetError,.invalidLedger) }
        }
        let path = dir.appendingPathComponent("live-budget.json")
        try Data("{\"schemaVersion\":1,\"schemaVersion\":1}".utf8).write(to:path)
        do { try await reserve(ledger);XCTFail() } catch { XCTAssertEqual(error as? MetaBudgetError,.invalidLedger) }
    }
    func testExpiredCancelledDeadlineAndContendedLockLeaveLedgerUntouched() async throws {
        let dir = try directory();try save(initial(),to:dir)
        do { try await reserve(budget(dir,now:MetaFileAttemptBudget.validUntilSeconds));XCTFail() } catch { XCTAssertEqual(error as? MetaBudgetError,.expired) }
        do { try await reserve(budget(dir),deadline:.now.advanced(by:.seconds(-1)));XCTFail() } catch { XCTAssertEqual(error as? ModelRoutingError,.deadlineExceeded) }
        let ledger = try budget(dir)
        let task = Task { try? await Task.sleep(for:.milliseconds(10));try await reserve(ledger) };task.cancel()
        do { try await task.value;XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let lock = open(dir.appendingPathComponent("live-budget.lock").path,O_CREAT | O_RDWR,mode_t(0o600));XCTAssertGreaterThanOrEqual(lock,0)
        defer { _ = close(lock) };XCTAssertEqual(flock(lock,LOCK_EX | LOCK_NB),0)
        do { try await reserve(ledger);XCTFail() } catch { XCTAssertEqual(error as? MetaBudgetError,.busy) }
        XCTAssertEqual((try load(dir)["attempts"] as? [Any])?.count,0)
    }
    func testPythonProcessLockPreventsSwiftReservation() async throws {
        let dir = try directory();try save(initial(),to:dir)
        let process = Process(),ready = Pipe(),release = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/env")
        process.arguments = ["python3","-c", """
        import os,fcntl,sys
        fd=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR,0o600)
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        sys.stdout.write('R');sys.stdout.flush()
        sys.stdin.read(1)
        os.close(fd)
        """,dir.appendingPathComponent("live-budget.lock").path]
        process.standardOutput = ready;process.standardInput = release
        try process.run()
        defer { try? release.fileHandleForWriting.close();process.waitUntilExit() }
        XCTAssertEqual(try ready.fileHandleForReading.read(upToCount:1),Data("R".utf8))
        do { try await reserve(budget(dir));XCTFail() } catch { XCTAssertEqual(error as? MetaBudgetError,.busy) }
        XCTAssertEqual((try load(dir)["attempts"] as? [Any])?.count,0)
        try release.fileHandleForWriting.write(contentsOf:Data("X".utf8));process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0)
        try await reserve(budget(dir))
        XCTAssertEqual((try load(dir)["attempts"] as? [Any])?.count,1)
    }
    func testPythonDriverReadsSwiftReservationAndSwiftRetainsPythonReservation() async throws {
        let dir = try directory();try save(initial(),to:dir);try await reserve(budget(dir))
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process();process.executableURL = URL(fileURLWithPath:"/usr/bin/env")
        process.arguments = ["python3","-c", """
        import importlib.util,json,sys,datetime,pathlib
        spec=importlib.util.spec_from_file_location('budget',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        p=pathlib.Path(sys.argv[2]);d=json.loads(m.private_file(p,262144))
        assert m.validate(d)==1000
        m.reserve(d,'sam-3.1',datetime.datetime(2026,11,1,tzinfo=datetime.timezone.utc));m.save(p,d)
        """,root.appendingPathComponent("Scripts/test-meta-live.py").path,dir.appendingPathComponent("live-budget.json").path]
        try process.run();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        try await reserve(budget(dir))
        let attempts = try XCTUnwrap(load(dir)["attempts"] as? [[String:Any]])
        XCTAssertEqual(attempts.count,3);XCTAssertEqual(attempts[1]["model"] as? String,"sam-3.1")
    }
}
