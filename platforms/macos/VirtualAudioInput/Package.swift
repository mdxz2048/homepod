// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VirtualAudioInput",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "VirtualAudioInput", targets: ["VirtualAudioInput"]),
        .executable(name: "virtual-audio-input", targets: ["VirtualAudioInputCLI"])
    ],
    dependencies: [
        .package(path: "../ProcessTapCapture")
    ],
    targets: [
        .target(name: "HALInputConstants", publicHeadersPath: "include"),
        .target(name: "VirtualAudioInput", dependencies: [
            "HALInputConstants",
            .product(name: "CaptureRing", package: "ProcessTapCapture")
        ], linkerSettings: [.linkedFramework("CoreAudio")]),
        .executableTarget(name: "VirtualAudioInputCLI", dependencies: ["VirtualAudioInput"]),
        .testTarget(name: "VirtualAudioInputTests", dependencies: ["VirtualAudioInput"])
    ]
)
