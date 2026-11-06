// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VirtualAudioInput",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "VirtualAudioInput", targets: ["VirtualAudioInput"]),
        .executable(name: "virtual-audio-input", targets: ["VirtualAudioInputCLI"]),
        .library(name: "VirtualCaptureHostSupport", targets: ["VirtualCaptureHostSupport"]),
        .executable(name: "virtual-audio-host", targets: ["VirtualCaptureHost"])
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
        .target(name: "VirtualCaptureHostSupport", dependencies: ["VirtualAudioInput",
            .product(name: "TapCaptureHostSupport", package: "ProcessTapCapture")]),
        .executableTarget(name: "VirtualCaptureHost", dependencies: ["VirtualCaptureHostSupport",
            .product(name: "TapCaptureHostSupport", package: "ProcessTapCapture")]),
        .testTarget(name: "VirtualCaptureHostTests", dependencies: ["VirtualCaptureHostSupport", "VirtualAudioInput",
            .product(name: "TapCaptureHostSupport", package: "ProcessTapCapture")]),
        .testTarget(name: "VirtualAudioInputTests", dependencies: ["VirtualAudioInput"])
    ]
)
