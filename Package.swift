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
    ],
    targets: [
        .target(name: "SquidraDomain"),
    ] + applicationModules.map { .target(name: $0, dependencies: ["SquidraDomain"]) } + [
        .target(name: "SquidraPostgres", dependencies: ["SquidraDomain", "SquidraWorld"]),
        .target(name: "SquidraMeta", dependencies: ["SquidraDomain", "SquidraCognition", "SquidraPerception"]),
        .executableTarget(
            name: "SquidraServer",
            dependencies: applicationModules.map { .byName(name: $0) } + [
                "SquidraDomain", "SquidraPostgres", "SquidraMeta",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .testTarget(name: "SquidraDomainTests", dependencies: ["SquidraDomain"]),
        .testTarget(name: "SquidraTemporalTests", dependencies: ["SquidraDomain", "SquidraTemporal"]),
        .testTarget(name: "SquidraCognitionTests", dependencies: ["SquidraDomain", "SquidraCognition", "SquidraMeta"]),
    ],
    swiftLanguageModes: [.v6]
)
