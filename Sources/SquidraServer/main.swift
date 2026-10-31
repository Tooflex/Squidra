import Foundation
import Hummingbird
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum ServerMain {
    static func run() async -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] {
            print("Usage: squidra serve | check-config | --version | --help")
            print("serve requires SQUIDRA_AUTH_TOKEN, SQUIDRA_ACTOR_ID, SQUIDRA_UI_ORIGIN,")
            print("SQUIDRA_DB_PORT, SQUIDRA_DB_USER, SQUIDRA_DB_PASSWORD and SQUIDRA_DB_NAME.")
            print("Optional: SQUIDRA_PORT (default 8080), SQUIDRA_PROFILE (offline only).")
            return 0
        }
        if arguments == ["--version"] { print("Squidra development (SwiftPM)"); return 0 }
        guard arguments == ["serve"] || arguments == ["check-config"] else {
            FileHandle.standardError.write(Data("Invalid command. Use squidra --help.\n".utf8))
            return 2
        }
        do {
            let configuration = try ServerConfiguration(environment: ProcessInfo.processInfo.environment)
            if arguments == ["check-config"] { print("SQUIDRA configuration valid"); return 0 }
            // Hummingbird ServiceLifecycle handles SIGINT/SIGTERM, drains requests,
            // and then shuts down the owned client pool. No direct signal handler.
            try await ServerComposition.live(configuration: configuration).runService()
            return 0
        } catch {
            // Never print configuration values, raw errors, SQL or connection strings.
            FileHandle.standardError.write(Data("SQUIDRA could not start or complete shutdown. Check configuration and local dependencies.\n".utf8))
            return 1
        }
    }
}
exit(await ServerMain.run())
