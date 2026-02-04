// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EchoUI",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "EchoUI",
            targets: ["EchoUI"]
        )
    ],
    dependencies: [
        .package(path: "../EchoCore")
    ],
    targets: [
        .target(
            name: "EchoUI",
            dependencies: ["EchoCore"],
            path: "Sources/EchoUI"
        ),
        .testTarget(
            name: "EchoUITests",
            dependencies: ["EchoUI"],
            path: "Tests/EchoUITests"
        )
    ]
)
