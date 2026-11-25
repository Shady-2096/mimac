// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MimacSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CShim"),
        .target(
            name: "MimacCore",
            dependencies: ["CShim"],
            path: "Sources/MimacCore"
        ),
        .target(
            name: "MimacIdentity",
            dependencies: ["MimacCore"],
            path: "Sources/MimacIdentity"
        ),
        .target(
            name: "MimacHistory",
            dependencies: ["MimacIdentity"],
            path: "Sources/MimacHistory",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "mimac-spike",
            dependencies: ["CShim", "MimacCore"],
            path: "Sources/mimac-spike"
        ),
        .executableTarget(
            name: "mimacd",
            dependencies: ["CShim", "MimacCore", "MimacIdentity", "MimacHistory"],
            path: "Sources/mimacd"
        ),
        .executableTarget(
            name: "mimacctl",
            dependencies: ["MimacIdentity"],
            path: "Sources/mimacctl"
        ),
        .executableTarget(
            name: "mimac-calibrate",
            dependencies: ["MimacIdentity"],
            path: "Sources/mimac-calibrate"
        ),
        .executableTarget(
            name: "Mimac",
            dependencies: ["MimacIdentity"],
            path: "Sources/MimacApp",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MimacIdentityTests",
            dependencies: ["MimacIdentity"],
            path: "Tests/MimacIdentityTests"
        ),
        .testTarget(
            name: "MimacHistoryTests",
            dependencies: ["MimacHistory", "MimacIdentity"],
            path: "Tests/MimacHistoryTests"
        )
    ]
)
