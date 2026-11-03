import Foundation
import CSquidraPlatform
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Host-owned current authority, retained independently of database backups.
/// Every read is bounded and fails closed; never provisions an empty registry.
struct ErasureAuthority: Sendable {
    enum Invalid: Error { case unavailable }
    let directory: URL
    init(environment: [String: String]) throws {
        guard let path = environment["SQUIDRA_ERASURE_AUTHORITY_DIRECTORY"],
              path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { throw Invalid.unavailable }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        guard let resolved = realpath(path, nil) else { throw Invalid.unavailable }
        defer { free(resolved) }
        guard String(cString: resolved) == path else { throw Invalid.unavailable }
    }
    /// Native CLI entrypoint only, once per process. The kernel owns this descriptor
    /// after success: do not close it at service return or ARC deinitialization.
    /// This keeps erasure excluded until process exit has stopped all threads.
    func holdUntilProcessExit(_ actor: UUID) throws {
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Invalid.unavailable }
        defer { _ = close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Invalid.unavailable }
        let fd = openat(parent, actor.uuidString.lowercased() + ".process.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw Invalid.unavailable }
        var retained = false
        defer { if !retained { _ = close(fd) } }
        try check(fd)
        guard squidra_filesystem_is_local(fd) == 1,
              flock(fd, LOCK_SH | LOCK_NB) == 0,
              fstat(fd, &info) == 0, info.st_nlink == 1, info.st_size == 0,
              fsync(fd) == 0, fsync(parent) == 0 else { throw Invalid.unavailable }
        // Recheck only after owning the lease: an administrator holding EX cannot
        // race a stale admission into the deletion interval.
        guard try admits(actor) else { throw Invalid.unavailable }
        retained = true
    }
    func admits(_ actor: UUID) throws -> Bool {
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Invalid.unavailable }
        defer { _ = close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Invalid.unavailable }
        let lock = openat(parent, "authority.lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard lock >= 0 else { throw Invalid.unavailable }
        defer { _ = close(lock) }
        try check(lock)
        // A writer/restorer in progress denies admission without blocking an event loop.
        guard flock(lock, LOCK_SH | LOCK_NB) == 0 else { throw Invalid.unavailable }
        let fd = openat(parent, "decisions.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Invalid.unavailable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        try check(fd)
        let bytes = try file.read(upToCount: 1_048_577) ?? Data()
        guard bytes.count <= 1_048_576 else { throw Invalid.unavailable }
        struct Registry: Decodable { let actors: [String]; let schemaVersion: Int }
        let registry = try JSONDecoder().decode(Registry.self, from: bytes)
        guard registry.schemaVersion == 1, registry.actors == Array(Set(registry.actors)).sorted(),
              registry.actors.allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }) else { throw Invalid.unavailable }
        // Canonical comparison also rejects duplicate/unknown JSON keys and alternate encodings.
        let members = registry.actors.map { "\"" + $0 + "\"" }.joined(separator: ",")
        guard bytes == Data(("{\"actors\":[" + members + "],\"schemaVersion\":1}\n").utf8) else { throw Invalid.unavailable }
        return !registry.actors.contains(actor.uuidString.lowercased())
    }
    private func check(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Invalid.unavailable }
    }
}
