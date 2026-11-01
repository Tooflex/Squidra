import Foundation
import Hummingbird
import SquidraAgentRuntime
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum ServerMain {
    static func run() async -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] {
            print("Usage: squidra serve | check-config | consolidate --input PATH | --version | --help")
            print("serve requires SQUIDRA_AUTH_TOKEN, SQUIDRA_ACTOR_ID, SQUIDRA_UI_ORIGIN,")
            print("SQUIDRA_DB_PORT, SQUIDRA_DB_USER, SQUIDRA_DB_PASSWORD and SQUIDRA_DB_NAME.")
            print("consolidate imports a bounded local JSON batch using the same actor/database configuration.")
            print("Optional: SQUIDRA_PORT (default 8080), SQUIDRA_PROFILE (offline only).")
            print("Optional: SQUIDRA_RUN_DIRECTORY (existing private local directory for run recovery).")
            print("Optional synthetic import: SQUIDRA_SYNTHETIC_IMPORT=1 with SQUIDRA_SYNTHETIC_FIXTURE,")
            print("SQUIDRA_SYNTHETIC_CAMERA_ID, SQUIDRA_SYNTHETIC_SCENE_ID and SQUIDRA_SYNTHETIC_COORDINATE_FRAME_ID.")
            return 0
        }
        if arguments == ["--version"] { print("Squidra development (SwiftPM)"); return 0 }
        let importing = arguments.count == 3 && arguments[0] == "consolidate" && arguments[1] == "--input"
        guard arguments == ["serve"] || arguments == ["check-config"] || importing else {
            FileHandle.standardError.write(Data("Invalid command. Use squidra --help.\n".utf8))
            return 2
        }
        do {
            let configuration = try ServerConfiguration(environment: ProcessInfo.processInfo.environment)
            if importing {
                let result = try await ConsolidationImportCommand.run(configuration: configuration, path: arguments[2])
                FileHandle.standardOutput.write(result + Data("\n".utf8)); return 0
            }
            if arguments == ["check-config"] { print("SQUIDRA configuration valid"); return 0 }
            let ownership = try configuration.localRunDirectory.map {
                try LocalRunOwnership.acquire(directory:$0,actorID:configuration.boundary.actorID)
            }
            defer { ownership?.releaseAfterJoiningWorkers() }
            // Hummingbird ServiceLifecycle handles SIGINT/SIGTERM, drains requests,
            // and then shuts down the owned client pool. No direct signal handler.
            try await ServerComposition.live(configuration: configuration,localOwnership:ownership).runService()
            return 0
        } catch {
            // Never print configuration values, raw errors, SQL or connection strings.
            let message = importing ? "SQUIDRA could not import the batch. Check the input, actor configuration and local database.\n" : "SQUIDRA could not start or complete shutdown. Check configuration and local dependencies.\n"
            FileHandle.standardError.write(Data(message.utf8))
            return 1
        }
    }
}
exit(await ServerMain.run())
