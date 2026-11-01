import Foundation
import CSquidraPlatform
import SquidraAgentRuntime
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class LocalRunOwnershipTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("squidra-owner-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        return path
    }
    func testFilesystemBridgeFailsClosedAndPreservesLocalAllowlist() {
        XCTAssertEqual(squidra_filesystem_is_local(-1), -1)
        for magic: UInt64 in [0xef53,0x01021994,0x58465342,0x9123683e,0x794c7630,0x2fc12fc1,0x858458f6] {
            XCTAssertEqual(squidra_linux_filesystem_type_is_local(magic), 1)
        }
        // NFS, CIFS, SMB2, FUSE, unknown and zero are not qualified local stores.
        for magic: UInt64 in [0x6969,0xff534d42,0xfe534d42,0x65735546,UInt64.max,0] {
            XCTAssertEqual(squidra_linux_filesystem_type_is_local(magic), 0)
        }
    }
    func testExclusiveOwnershipStableDomainAndIndependentActors() throws {
        let path = try directory();defer { try? FileManager.default.removeItem(at:path) }
        let actor = UUID(),first = try LocalRunOwnership.acquire(directory:path,actorID:actor)
        XCTAssertTrue(first.isHeld)
        XCTAssertThrowsError(try LocalRunOwnership.acquire(directory:path,actorID:actor)) { error in
            guard case LocalRunOwnershipError.busy = error else { return XCTFail("Unexpected lock failure") }
        }
        let other = try LocalRunOwnership.acquire(directory:path,actorID:UUID())
        XCTAssertNotEqual(first.domainID,other.domainID);other.releaseAfterJoiningWorkers()
        first.releaseAfterJoiningWorkers();XCTAssertFalse(first.isHeld)
        let next = try LocalRunOwnership.acquire(directory:path,actorID:actor)
        XCTAssertEqual(next.fileID,first.fileID);XCTAssertEqual(next.domainID,first.domainID);XCTAssertNotEqual(next.ownerID,first.ownerID)
        next.releaseAfterJoiningWorkers();next.releaseAfterJoiningWorkers()
    }
    func testCopiedIdentityHasDifferentFileIdentityAndCannotProveOldOwnership() throws {
        let firstPath = try directory(),copyPath = try directory()
        defer { try? FileManager.default.removeItem(at:firstPath);try? FileManager.default.removeItem(at:copyPath) }
        let actor = UUID(),first = try LocalRunOwnership.acquire(directory:firstPath,actorID:actor)
        defer { first.releaseAfterJoiningWorkers() }
        let name = actor.uuidString.lowercased()+".lock"
        try FileManager.default.copyItem(at:firstPath.appendingPathComponent(name),to:copyPath.appendingPathComponent(name))
        let copy = try LocalRunOwnership.acquire(directory:copyPath,actorID:actor)
        defer { copy.releaseAfterJoiningWorkers() }
        XCTAssertEqual(first.domainID,copy.domainID)
        XCTAssertNotEqual(first.fileID,copy.fileID)
        XCTAssertTrue(first.isHeld)
    }
    func testUnsafeAndMalformedFilesCannotAuthorizeOwnership() throws {
        let path = try directory();defer { try? FileManager.default.removeItem(at:path) }
        let actor = UUID(),file = path.appendingPathComponent(actor.uuidString.lowercased()+".lock")
        try Data("broken".utf8).write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        XCTAssertThrowsError(try LocalRunOwnership.acquire(directory:path,actorID:actor))
        try FileManager.default.removeItem(at:file)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:path.appendingPathComponent("target"))
        XCTAssertThrowsError(try LocalRunOwnership.acquire(directory:path,actorID:actor))
        try FileManager.default.removeItem(at:file)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:path.path)
        XCTAssertThrowsError(try LocalRunOwnership.acquire(directory:path,actorID:actor))
    }
    func testOwnedProcessDeathReleasesKernelLockWithoutReplacingIdentity() throws {
        let path = try directory();defer { try? FileManager.default.removeItem(at:path) }
        let actor = UUID(),first = try LocalRunOwnership.acquire(directory:path,actorID:actor),domain = first.domainID
        first.releaseAfterJoiningWorkers()
        let child = Process(),output = Pipe()
        child.executableURL = URL(fileURLWithPath:"/usr/bin/env")
        child.arguments = ["python3","-c","import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.flock(f,fcntl.LOCK_EX); print('LOCKED',flush=True); time.sleep(30)",path.appendingPathComponent(actor.uuidString.lowercased()+".lock").path]
        child.standardOutput = output;child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { _ = kill(child.processIdentifier,SIGKILL);child.waitUntilExit() } }
        // Poll only our pipe with a bounded timeout; never search or kill other PIDs.
        var descriptor = pollfd(fd:output.fileHandleForReading.fileDescriptor,events:Int16(POLLIN),revents:0)
        XCTAssertEqual(poll(&descriptor,1,5000),1)
        guard descriptor.revents & Int16(POLLIN) != 0 else { return XCTFail("Child did not acquire lock") }
        XCTAssertEqual(String(data:output.fileHandleForReading.availableData,encoding:.utf8),"LOCKED\n")
        XCTAssertThrowsError(try LocalRunOwnership.acquire(directory:path,actorID:actor))
        XCTAssertEqual(kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit()
        XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let resumed = try LocalRunOwnership.acquire(directory:path,actorID:actor)
        XCTAssertEqual(resumed.domainID,domain);resumed.releaseAfterJoiningWorkers()
    }
}
