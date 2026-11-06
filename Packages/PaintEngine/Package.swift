// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaintEngine",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PaintEngine", targets: ["PaintEngine"])],
    targets: [
        .target(name: "PaintEngine"),
        .testTarget(name: "PaintEngineTests", dependencies: ["PaintEngine"]),
    ],
    swiftLanguageModes: [.v6]
)
