// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypelessCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TypelessCore",
            targets: ["TypelessCore"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TypelessCore",
            path: "Sources/TypelessCore"
        ),
        .testTarget(
            name: "TypelessCoreTests",
            dependencies: ["TypelessCore"],
            path: "Tests/TypelessCoreTests"
        )
    ]
)
