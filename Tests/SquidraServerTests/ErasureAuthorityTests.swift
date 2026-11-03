import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import SquidraServer

final class ErasureAuthorityTests: XCTestCase {
    private func canonical(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw ErasureAuthority.Invalid.unavailable }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    private func fixture(_ body: (URL, ErasureAuthority) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("squidra-authority-test-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: path) }
        for name in ["authority.lock", "decisions.json"] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path.appendingPathComponent(name).path, contents: Data(), attributes: [.posixPermissions: 0o600]))
        }
        try Data("{\"actors\":[],\"schemaVersion\":1}\n".utf8).write(to: path.appendingPathComponent("decisions.json"))
        try body(path, ErasureAuthority(environment: ["SQUIDRA_ERASURE_AUTHORITY_DIRECTORY": canonical(path.path)]))
    }
    func testCanonicalDecisionRecheckedWithoutDatabaseFence() throws {
        try fixture { directory, authority in
            let actor = UUID(), other = UUID(), file = directory.appendingPathComponent("decisions.json")
            XCTAssertTrue(try authority.admits(actor))
            try Data(("{\"actors\":[\""+actor.uuidString.lowercased()+"\"],\"schemaVersion\":1}\n").utf8).write(to: file)
            XCTAssertFalse(try authority.admits(actor))
            XCTAssertTrue(try authority.admits(other))
        }
    }
    func testMalformedDuplicateUnknownAndOversizedRegistriesRefused() throws {
        try fixture { directory, authority in
            let file = directory.appendingPathComponent("decisions.json")
            for text in ["{}", "{\"actors\":[],\"actors\":[],\"schemaVersion\":1}\n", "{\"actors\":[],\"schemaVersion\":true}\n", "{\"actors\":[],\"schemaVersion\":1,\"other\":0}\n", "{\"actors\":[\"bad\"],\"schemaVersion\":1}\n", String(repeating: " ", count: 1_048_577)] {
                try Data(text.utf8).write(to: file)
                XCTAssertThrowsError(try authority.admits(UUID()))
            }
        }
    }
    func testMissingPublicLinkedAndNonregularFilesRefused() throws {
        try fixture { directory, authority in
            let file = directory.appendingPathComponent("decisions.json"), backup = directory.appendingPathComponent("backup")
            XCTAssertEqual(chmod(file.path, 0o644), 0)
            XCTAssertThrowsError(try authority.admits(UUID()))
            XCTAssertEqual(chmod(file.path, 0o600), 0)
            XCTAssertEqual(link(file.path, backup.path), 0)
            XCTAssertThrowsError(try authority.admits(UUID()))
            try FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: file, to: backup)
            XCTAssertThrowsError(try authority.admits(UUID()))
            XCTAssertEqual(symlink(backup.path, file.path), 0)
            XCTAssertThrowsError(try authority.admits(UUID()))
            try FileManager.default.removeItem(at: file)
            XCTAssertEqual(mkfifo(file.path, 0o600), 0)
            XCTAssertThrowsError(try authority.admits(UUID()))
        }
    }
    func testWriterLockDeniesPromptlyAndRecoversAfterRelease() throws {
        try fixture { directory, authority in
            let fd = open(directory.appendingPathComponent("authority.lock").path, O_RDWR)
            XCTAssertGreaterThanOrEqual(fd, 0); defer { _ = close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try authority.admits(UUID()))
            XCTAssertEqual(flock(fd, LOCK_UN), 0)
            XCTAssertTrue(try authority.admits(UUID()))
        }
    }
    func testMissingConfigurationAndPublicDirectoryRefused() throws {
        XCTAssertThrowsError(try ErasureAuthority(environment: [:]))
        XCTAssertThrowsError(try ErasureAuthority(environment: ["SQUIDRA_ERASURE_AUTHORITY_DIRECTORY":"relative"]))
        try fixture { directory, authority in
            XCTAssertEqual(chmod(directory.path, 0o755), 0)
            XCTAssertThrowsError(try authority.admits(UUID()))
            XCTAssertEqual(chmod(directory.path, 0o700), 0)
        }
    }
}
