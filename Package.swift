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
                .process("Renderer/Shaders.metal"),
                .process("Renderer/FogVolumeShaders.metal"),
                .process("Renderer/FeedbackShaders.metal"),
                .process("Renderer/LaserBeamShaders.metal"),
                .process("Renderer/WidgetShaders.metal"),
                .process("Renderer/ColorGradeShaders.metal"),
                .process("Renderer/IBLShaders.metal"),
                .copy("Renderer/brown_photostudio_02_2k.hdr"),
                .copy("Renderer/studio_small_08_2k.hdr")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreVideo")
            ]
        )
    ]
)
