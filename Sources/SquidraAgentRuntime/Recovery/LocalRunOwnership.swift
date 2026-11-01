import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum LocalRunOwnershipError: Error, Sendable { case unavailable, busy, unsafePath, invalidIdentity, unsupportedFilesystem }

/// Exclusive local-process ownership for one actor. The host must retain this
/// handle until every worker has stopped and joined, including cancellation.
/// It must persist domainID AND fileID with admitted runs; a newly created file never proves
/// ownership of runs associated with another domain. Not a distributed lease.
public final class LocalRunOwnership: @unchecked Sendable {
    public let domainID: UUID,ownerID = UUID(),actorID: UUID
    public let fileID: String
    private let mutex = NSLock()
    private var descriptor: Int32
    private init(descriptor: Int32,domainID: UUID,fileID: String,actorID: UUID) {
        self.descriptor = descriptor;self.domainID = domainID;self.fileID = fileID;self.actorID = actorID
    }
    public static func acquire(directory: URL,actorID: UUID) throws -> LocalRunOwnership {
        guard directory.isFileURL,directory.path.hasPrefix("/"),!directory.path.contains("\0") else { throw LocalRunOwnershipError.unsafePath }
        // The caller supplies an existing private directory. Open relative to its
        // descriptor so a subsequent path rename cannot redirect the lock file.
        let parent = open(directory.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw LocalRunOwnershipError.unsafePath }
        defer { _ = close(parent) }
        var parentInfo = stat()
        guard fstat(parent,&parentInfo) == 0,parentInfo.st_uid == geteuid(),parentInfo.st_mode & 0o077 == 0 else { throw LocalRunOwnershipError.unsafePath }
        let name = actorID.uuidString.lowercased()+".lock"
        let fd = openat(parent,name,O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,mode_t(0o600))
        guard fd >= 0 else { throw LocalRunOwnershipError.unsafePath }
        var transferred = false
        defer { if !transferred { _ = close(fd) } }
        var info = stat()
        guard fstat(fd,&info) == 0,info.st_uid == geteuid(),info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o077 == 0,info.st_nlink == 1 else { throw LocalRunOwnershipError.unsafePath }
        var filesystem = statfs()
        guard fstatfs(fd,&filesystem) == 0 else { throw LocalRunOwnershipError.unavailable }
        #if canImport(Darwin)
        guard filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw LocalRunOwnershipError.unsupportedFilesystem }
        #else
        // Local filesystems only: ext, tmpfs, XFS, Btrfs, overlay, ZFS, ramfs.
        guard [Int64(0xef53),0x01021994,0x58465342,0x9123683e,0x794c7630,0x2fc12fc1,0x858458f6].contains(Int64(filesystem.f_type)) else { throw LocalRunOwnershipError.unsupportedFilesystem }
        #endif
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK || errno == EAGAIN ? LocalRunOwnershipError.busy : LocalRunOwnershipError.unavailable
        }
        // Recheck after acquiring: identity writes from the old owner are complete.
        guard fstat(fd,&info) == 0,info.st_nlink == 1,info.st_size <= 37 else { throw LocalRunOwnershipError.invalidIdentity }
        let domain: UUID
        if info.st_size == 0 {
            domain = UUID()
            let bytes = Array((domain.uuidString.lowercased()+"\n").utf8)
            let written = bytes.withUnsafeBytes { pwrite(fd,$0.baseAddress,bytes.count,0) }
            guard written == bytes.count,fsync(fd) == 0,fsync(parent) == 0 else { throw LocalRunOwnershipError.unavailable }
        } else {
            guard info.st_size == 37 else { throw LocalRunOwnershipError.invalidIdentity }
            var bytes = [UInt8](repeating:0,count:37)
            let count = bytes.withUnsafeMutableBytes { pread(fd,$0.baseAddress,37,0) }
            guard count == 37,let text = String(bytes:bytes,encoding:.utf8),text.last == "\n",
                  let value = UUID(uuidString:String(text.dropLast())),value.uuidString.lowercased()+"\n" == text else { throw LocalRunOwnershipError.invalidIdentity }
            domain = value
        }
        transferred = true
        return LocalRunOwnership(descriptor:fd,domainID:domain,fileID:String(info.st_dev)+":"+String(info.st_ino),actorID:actorID)
    }
    public var isHeld: Bool { mutex.withLock { descriptor >= 0 } }
    /// Only after owned workers are joined. Never unlink the lock file: its
    /// persistent identity distinguishes old runs from a replacement directory.
    public func releaseAfterJoiningWorkers() {
        mutex.withLock { if descriptor >= 0 { _ = close(descriptor);descriptor = -1 } }
    }
    deinit { if descriptor >= 0 { _ = close(descriptor) } }
}
