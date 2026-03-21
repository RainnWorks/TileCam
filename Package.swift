// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GlassView",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "GlassView", targets: ["GlassView"])
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC", exact: "140.0.0")
    ],
    targets: [
        .target(
            name: "GlassView",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC")
            ],
            path: "GlassView"
        )
    ]
)
