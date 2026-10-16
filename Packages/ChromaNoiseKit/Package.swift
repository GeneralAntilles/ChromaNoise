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
            dependencies: [.product(name: "Atomics", package: "swift-atomics")],
            // The worker's pure-Swift FFT runs ~3× too slow for realtime at
            // -Onone, so Debug app builds underrun the ring (audible stutter).
            // Always optimize the DSP; app code stays debuggable.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(
            name: "ChromaNoiseKitTests",
            dependencies: ["ChromaNoiseKit"]
        ),
    ]
)
