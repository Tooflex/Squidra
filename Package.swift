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
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.28.1"),
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.33.2"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.2"),
        .package(url: "https://github.com/ajevans99/swift-json-schema.git", exact: "0.14.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"),
    ],
    targets: [
        .target(name: "SquidraDomain"),
    ] + applicationModules.map { name in
        .target(name: name, dependencies: [.byName(name: "SquidraDomain")] +
            (name == "SquidraSecurity" ? [.product(name: "Crypto", package: "swift-crypto")] : []) +
            (name == "SquidraTools" ? [.byName(name: "SquidraSecurity"), .product(name: "JSONSchema", package: "swift-json-schema"), .product(name: "Crypto", package: "swift-crypto")] : []))
    } + [
        .target(name: "SquidraPostgres", dependencies: ["SquidraDomain", "SquidraWorld", "SquidraAgentRuntime", "SquidraTools", "SquidraSecurity", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")]),
        .target(name: "SquidraMeta", dependencies: ["SquidraDomain", "SquidraCognition", "SquidraPerception"]),
        .executableTarget(
            name: "SquidraServer",
            dependencies: applicationModules.map { .byName(name: $0) } + [
                "SquidraDomain", "SquidraPostgres", "SquidraMeta",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .testTarget(name: "SquidraPostgresSwiftTests", dependencies: ["SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "SquidraServerTests", dependencies: ["SquidraServer", "SquidraProtocols", "SquidraPostgres", .product(name: "HummingbirdTesting", package: "hummingbird")], exclude: ["server_process.py"]),
        .testTarget(name: "SquidraAgentRuntimeTests", dependencies: ["SquidraDomain", "SquidraAgentRuntime", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "SquidraSecurityTests", dependencies: ["SquidraSecurity", "SquidraTools", "SquidraDomain", "SquidraTemporal", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "SquidraToolsTests", dependencies: ["SquidraTools", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "SquidraDomainTests", dependencies: ["SquidraDomain"]),
        .testTarget(name: "SquidraTemporalTests", dependencies: ["SquidraDomain", "SquidraTemporal"]),
        .testTarget(name: "SquidraCognitionTests", dependencies: ["SquidraDomain", "SquidraCognition", "SquidraMeta"]),
    ],
    swiftLanguageModes: [.v6]
)
