// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EchoCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "EchoCore",
            targets: ["EchoCore"]
        ),
        .executable(
            name: "ASRBenchmarkCLI",
            targets: ["ASRBenchmarkCLI"]
        ),
        .executable(
            name: "ASRStreamSmokeCLI",
            targets: ["ASRStreamSmokeCLI"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "EchoCore",
            dependencies: [],
            path: "Sources/EchoCore"
        ),
        .executableTarget(
            name: "ASRBenchmarkCLI",
            dependencies: ["EchoCore"],
            path: "Sources/ASRBenchmarkCLI"
        ),
        .executableTarget(
            name: "ASRStreamSmokeCLI",
            dependencies: ["EchoCore"],
            path: "Sources/ASRStreamSmokeCLI"
        ),
        .testTarget(
            name: "EchoCoreTests",
            dependencies: ["EchoCore"],
            path: "Tests/EchoCoreTests"
        )
    ]
)
