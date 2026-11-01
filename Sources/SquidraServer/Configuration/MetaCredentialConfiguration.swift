import Foundation
import SquidraMeta
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum MetaCredentialConfiguration {
    enum Invalid: Error { case credential }
    static func read(environment: [String:String]) throws -> String {
        let key: String
        switch (environment["MODEL_API_KEY"],environment["MODEL_API_KEY_FILE"]) {
        case let (.some(value),.none): key = value
        case let (.none,.some(path)): key = try readKey(path)
        default: throw Invalid.credential
        }
        // Validate even with an injected offline transport; never expose the key.
        _ = try MetaHTTPSResponseTransport(apiKey:key)
        return key
    }
    private static func readKey(_ path: String) throws -> String {
        guard path.hasPrefix("/"),!path.contains("\0"),path.utf8.count <= 4096 else { throw Invalid.credential }
        let fd = open(path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Invalid.credential };defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_uid == geteuid(),info.st_nlink == 1,
              info.st_mode & 0o7777 == 0o600,(1...4096).contains(info.st_size) else { throw Invalid.credential }
        let data = try FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:4097) ?? Data()
        guard data.count == info.st_size,let key = String(data:data,encoding:.ascii) else { throw Invalid.credential }
        return key
    }
}
