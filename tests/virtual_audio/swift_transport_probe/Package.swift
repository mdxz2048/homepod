// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VirtualTransportCheck",
    platforms: [.macOS("14.2")],
    dependencies: [.package(path: "../../../platforms/macos/VirtualAudioInput")],
    targets: [.executableTarget(name: "VirtualTransportCheck", dependencies: [
        .product(name: "VirtualAudioInput", package: "VirtualAudioInput")
    ])]
)
