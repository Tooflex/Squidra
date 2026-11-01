// swift-tools-version: 6.4
import PackageDescription

let applicationModules = [
    "SquidraAgentRuntime", "SquidraCognition", "SquidraTemporal",
    "SquidraSpatial", "SquidraWorld", "SquidraPerception", "SquidraMemory",
    "SquidraSecurity", "SquidraTools", "SquidraProtocols", "SquidraObservability",
]

let package = Package(
    name: "Squidra",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SquidraDomain", targets: ["SquidraDomain"]),
        .executable(name: "squidra", targets: ["SquidraServer"]),
        .executable(name: "squidra-eval", targets: ["EvalRunner"]),
        .executable(name: "squidra-eval-database", targets: ["DatabaseEval"]),
        .executable(name: "squidra-run-crash-fixture", targets: ["RunCrashFixture"]),
        .executable(name: "squidra-movement-crash-fixture", targets: ["MovementCrashFixture"]),
        .executable(name: "squidra-watch-crash-fixture", targets: ["WatchCrashFixture"]),
        .executable(name: "squidra-publication-crash-fixture", targets: ["PublicationCrashFixture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.13.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.28.1"),
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.33.2"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.2"),
        .package(url: "https://github.com/ajevans99/swift-json-schema.git", exact: "0.14.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", exact: "2.6.0"),
    ],
    targets: [
        .target(name: "SquidraDomain"),
    ] + applicationModules.map { name in
        .target(name: name, dependencies: [.byName(name: "SquidraDomain")] +
            (name == "SquidraCognition" ? [.byName(name: "SquidraWorld"), .byName(name: "SquidraTools"), .byName(name: "SquidraMemory")] : []) +
            (name == "SquidraAgentRuntime" ? [.byName(name: "SquidraSecurity"), .byName(name: "SquidraCognition"), .byName(name: "SquidraTools")] : []) +
            (name == "SquidraProtocols" ? [.byName(name: "SquidraCognition")] : []) +
            (name == "SquidraPerception" ? [.byName(name: "SquidraWorld"), .byName(name: "SquidraSpatial"), .product(name: "Crypto", package: "swift-crypto")] : []) +
            (name == "SquidraObservability" ? [.byName(name: "SquidraCognition"), .byName(name: "SquidraWorld"), .byName(name: "SquidraTools"), .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"), .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"), .product(name: "NIOConcurrencyHelpers", package: "swift-nio")] : []) +
            (name == "SquidraSecurity" ? [.product(name: "Crypto", package: "swift-crypto")] : []) +
            (name == "SquidraTools" ? [.byName(name: "SquidraMemory"), .byName(name: "SquidraWorld"), .byName(name: "SquidraSecurity"), .product(name: "JSONSchema", package: "swift-json-schema"), .product(name: "Crypto", package: "swift-crypto")] : []))
    } + [
        .executableTarget(name: "DatabaseEval", dependencies: ["SquidraDomain", "SquidraWorld", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio")], path: "Evals/Database"),
        .executableTarget(name: "EvalRunner", dependencies: ["SquidraDomain", "SquidraTemporal", "SquidraSpatial", "SquidraPerception"], path: "Evals/Runner"),
        .executableTarget(name: "MovementCrashFixture", dependencies: ["SquidraPerception", "SquidraSpatial", "SquidraDomain", "SquidraWorld", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio")], path: "Tests/MovementCrashFixture"),
        .executableTarget(name: "WatchCrashFixture", dependencies: ["SquidraMemory", "SquidraPerception", "SquidraSpatial", "SquidraDomain", "SquidraWorld", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio")], path: "Tests/WatchCrashFixture"),
        .executableTarget(name: "PublicationCrashFixture", dependencies: ["SquidraAgentRuntime", "SquidraCognition", "SquidraDomain", "SquidraPostgres", "SquidraProtocols", "SquidraSecurity", "SquidraTemporal", "SquidraTools", .product(name: "PostgresNIO", package: "postgres-nio")], path: "Tests/PublicationCrashFixture"),
        .executableTarget(name: "RunCrashFixture", dependencies: ["SquidraAgentRuntime", "SquidraTools", "SquidraDomain", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio")], path: "Tests/RunCrashFixture"),
        .target(name: "SquidraPostgres", dependencies: ["SquidraCognition", "SquidraMemory", "SquidraSpatial", "SquidraProtocols", "SquidraDomain", "SquidraWorld", "SquidraAgentRuntime", "SquidraTools", "SquidraSecurity", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log"), "SquidraPerception"]),
        .target(name: "SquidraMeta", dependencies: ["SquidraDomain", "SquidraCognition", "SquidraPerception", .product(name: "Crypto", package: "swift-crypto")]),
        .executableTarget(
            name: "SquidraServer",
            dependencies: applicationModules.map { .byName(name: $0) } + [
                "SquidraDomain", "SquidraPostgres", "SquidraMeta",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .testTarget(name: "SquidraPostgresSwiftTests", dependencies: ["SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "SquidraServerTests", dependencies: ["SquidraMemory", "SquidraPerception", "SquidraSpatial", "SquidraServer", "SquidraObservability", "SquidraWorld", "SquidraProtocols", "SquidraDomain", "SquidraSecurity", "SquidraTools", "SquidraPostgres", .product(name: "HummingbirdTesting", package: "hummingbird"), "SquidraTemporal", "SquidraAgentRuntime", "SquidraCognition", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")], exclude: ["server_process.py"]),
        .testTarget(name: "SquidraAgentRuntimeTests", dependencies: ["SquidraDomain", "SquidraAgentRuntime", "SquidraCognition", "SquidraWorld", "SquidraTools", "SquidraSecurity", "SquidraTemporal", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "SquidraWorldTests", dependencies: ["SquidraDomain", "SquidraWorld", "SquidraPostgres", .product(name: "Crypto", package: "swift-crypto"), .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")], exclude: ["Fixtures"]),
        .testTarget(name: "SquidraSecurityTests", dependencies: ["SquidraSecurity", "SquidraTools", "SquidraDomain", "SquidraTemporal", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "SquidraToolsTests", dependencies: ["SquidraMemory", "SquidraDomain", "SquidraWorld", "SquidraSecurity", "SquidraTools", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "SquidraProtocolsTests", dependencies: ["SquidraProtocols", "SquidraCognition", "SquidraDomain", "SquidraWorld", .product(name: "JSONSchema", package: "swift-json-schema"), .product(name: "Crypto", package: "swift-crypto"), "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "SquidraIntegrationTests", dependencies: ["SquidraDomain", "SquidraWorld", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio")]),
        .testTarget(name: "SquidraPerceptionTests", dependencies: ["SquidraSpatial", "SquidraAgentRuntime", "SquidraCognition", "SquidraWorld", "SquidraTools", "SquidraSecurity", "SquidraTemporal", "SquidraDomain", "SquidraPerception", "SquidraMeta", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log"), .product(name: "Crypto", package: "swift-crypto")]),
        .testTarget(name: "SquidraProviderContractTests", dependencies: ["SquidraDomain", .product(name: "JSONSchema", package: "swift-json-schema"), .product(name: "Crypto", package: "swift-crypto")]),
        .testTarget(name: "SquidraObservabilityTests", dependencies: ["SquidraObservability", "SquidraDomain", "SquidraCognition", "SquidraSecurity", "SquidraTools", "SquidraWorld", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log"), .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"), .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core")]),
        .testTarget(name: "SquidraSpatialTests", dependencies: ["SquidraSpatial", "SquidraDomain", "SquidraPerception"]),
        .testTarget(name: "SquidraMemoryTests", dependencies: ["SquidraPostgres", "SquidraPerception", "SquidraSpatial", .product(name: "PostgresNIO", package: "postgres-nio"), "SquidraMemory", "SquidraCognition", "SquidraDomain", "SquidraAgentRuntime", "SquidraTools", "SquidraWorld", "SquidraSecurity", "SquidraTemporal"]),
        .testTarget(name: "SquidraDomainTests", dependencies: ["SquidraDomain"]),
        .testTarget(name: "SquidraTemporalTests", dependencies: ["SquidraDomain", "SquidraTemporal"]),
        .testTarget(name: "SquidraCognitionTests", dependencies: ["SquidraDomain", "SquidraCognition", "SquidraTools", "SquidraSecurity", "SquidraWorld", "SquidraMeta"]),
    ],
    swiftLanguageModes: [.v6]
)
