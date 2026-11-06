// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaintEngine",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PaintEngine", targets: ["PaintEngine"])],
    targets: [
        // Unoptimized the engine is ~100x slower, which makes the live preview unusable in Debug runs.
        .target(name: "PaintEngine", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .testTarget(name: "PaintEngineTests", dependencies: ["PaintEngine"]),
    ],
    swiftLanguageModes: [.v6]
)
