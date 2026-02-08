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
        )
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "10.25.0")
    ],
    targets: [
        .target(
            name: "EchoCore",
            dependencies: [
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestoreSwift", package: "firebase-ios-sdk"),
                .product(name: "FirebaseStorage", package: "firebase-ios-sdk")
            ],
            path: "Sources/EchoCore"
        ),
        .testTarget(
            name: "EchoCoreTests",
            dependencies: ["EchoCore"],
            path: "Tests/EchoCoreTests"
        )
    ]
)
