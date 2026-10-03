// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WiiUCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "WiiUCore", targets: ["WiiUCore"]),
    ],
    targets: [
        .target(
            name: "WiiUCore",
            path: "Sources/WiiUCore",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "WiiUCoreTests",
            dependencies: ["WiiUCore"],
            path: "Tests/WiiUCoreTests"
        ),
    ]
)
