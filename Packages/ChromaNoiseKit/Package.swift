// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChromaNoiseKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ChromaNoiseKit", targets: ["ChromaNoiseKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "ChromaNoiseKit",
            dependencies: [.product(name: "Atomics", package: "swift-atomics")]
        ),
        .testTarget(
            name: "ChromaNoiseKitTests",
            dependencies: ["ChromaNoiseKit"]
        ),
    ]
)
