import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import SquidraServer

/// Immutable, explicitly empty authority owned by this test process only.
enum ErasureAuthorityFixture {
    private static func canonical(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw ErasureAuthority.Invalid.unavailable }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    private final class Owner: @unchecked Sendable {
        let directory: URL
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("squidra-authority-" + UUID().uuidString).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for (name, bytes) in [("authority.lock", Data()), ("decisions.json", Data("{\"actors\":[],\"schemaVersion\":1}\n".utf8))] {
                guard FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { throw ErasureAuthority.Invalid.unavailable }
            }
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }
    private static let owner = Result { try Owner() }
    static func make() throws -> ErasureAuthority {
        try ErasureAuthority(environment: ["SQUIDRA_ERASURE_AUTHORITY_DIRECTORY": canonical(owner.get().directory.path)])
    }
}
