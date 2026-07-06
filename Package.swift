// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TileCam",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "TileCam", targets: ["TileCam"])
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC", exact: "140.0.0")
    ],
    targets: [
        .target(
            name: "TileCam",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC")
            ],
            path: "GlassView"
        )
    ]
)
