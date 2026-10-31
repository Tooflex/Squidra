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
            (name == "SquidraCognition" ? [.byName(name: "SquidraWorld"), .byName(name: "SquidraTools")] : []) +
            (name == "SquidraAgentRuntime" ? [.byName(name: "SquidraSecurity"), .byName(name: "SquidraCognition"), .byName(name: "SquidraTools")] : []) +
            (name == "SquidraProtocols" ? [.byName(name: "SquidraCognition")] : []) +
            (name == "SquidraSecurity" ? [.product(name: "Crypto", package: "swift-crypto")] : []) +
            (name == "SquidraTools" ? [.byName(name: "SquidraWorld"), .byName(name: "SquidraSecurity"), .product(name: "JSONSchema", package: "swift-json-schema"), .product(name: "Crypto", package: "swift-crypto")] : []))
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
        .testTarget(name: "SquidraServerTests", dependencies: ["SquidraServer", "SquidraProtocols", "SquidraDomain", "SquidraSecurity", "SquidraTools", "SquidraPostgres", .product(name: "HummingbirdTesting", package: "hummingbird")], exclude: ["server_process.py"]),
        .testTarget(name: "SquidraAgentRuntimeTests", dependencies: ["SquidraDomain", "SquidraAgentRuntime", "SquidraCognition", "SquidraWorld", "SquidraTools", "SquidraSecurity", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "SquidraWorldTests", dependencies: ["SquidraDomain", "SquidraWorld", "SquidraPostgres", .product(name: "Crypto", package: "swift-crypto"), .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")], exclude: ["Fixtures"]),
        .testTarget(name: "SquidraSecurityTests", dependencies: ["SquidraSecurity", "SquidraTools", "SquidraDomain", "SquidraTemporal", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "SquidraToolsTests", dependencies: ["SquidraDomain", "SquidraWorld", "SquidraSecurity", "SquidraTools", "SquidraPostgres", .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "SquidraProtocolsTests", dependencies: ["SquidraProtocols", "SquidraCognition", "SquidraDomain", "SquidraWorld", .product(name: "JSONSchema", package: "swift-json-schema"), .product(name: "Crypto", package: "swift-crypto")]),
        .testTarget(name: "SquidraSpatialTests", dependencies: ["SquidraSpatial", "SquidraDomain"]),
        .testTarget(name: "SquidraDomainTests", dependencies: ["SquidraDomain"]),
        .testTarget(name: "SquidraTemporalTests", dependencies: ["SquidraDomain", "SquidraTemporal"]),
        .testTarget(name: "SquidraCognitionTests", dependencies: ["SquidraDomain", "SquidraCognition", "SquidraTools", "SquidraSecurity", "SquidraWorld", "SquidraMeta"]),
    ],
    swiftLanguageModes: [.v6]
)
