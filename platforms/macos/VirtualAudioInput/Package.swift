// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VirtualAudioInput",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "VirtualAudioInput", targets: ["VirtualAudioInput"]),
        .executable(name: "virtual-audio-input", targets: ["VirtualAudioInputCLI"])
    ],
    targets: [
        .target(name: "HALInputConstants", publicHeadersPath: "include"),
        .target(name: "VirtualAudioInput", dependencies: ["HALInputConstants"], linkerSettings: [.linkedFramework("CoreAudio")]),
        .executableTarget(name: "VirtualAudioInputCLI", dependencies: ["VirtualAudioInput"]),
        .testTarget(name: "VirtualAudioInputTests", dependencies: ["VirtualAudioInput"])
    ]
)
