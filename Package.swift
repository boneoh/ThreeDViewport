// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThreeDViewport",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/warrenm/GLTFKit2.git", from: "0.5.0")
    ],
    targets: [
        .executableTarget(
            name: "ThreeDViewport",
            dependencies: [
                .product(name: "GLTFKit2", package: "GLTFKit2")
            ],
            path: "Sources/ThreeDViewport",
            resources: [
                .process("Renderer/Shaders.metal")
            ]
        )
    ]
)
