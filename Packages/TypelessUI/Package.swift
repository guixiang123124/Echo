// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypelessUI",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TypelessUI",
            targets: ["TypelessUI"]
        )
    ],
    dependencies: [
        .package(path: "../TypelessCore")
    ],
    targets: [
        .target(
            name: "TypelessUI",
            dependencies: ["TypelessCore"],
            path: "Sources/TypelessUI"
        ),
        .testTarget(
            name: "TypelessUITests",
            dependencies: ["TypelessUI"],
            path: "Tests/TypelessUITests"
        )
    ]
)
