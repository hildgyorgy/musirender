// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MusiRenderer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MusiRendererCore", targets: ["MusiRendererCore"])
    ],
    targets: [
        .target(name: "MusiRendererCore"),
        .testTarget(
            name: "MusiRendererCoreTests",
            dependencies: ["MusiRendererCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
