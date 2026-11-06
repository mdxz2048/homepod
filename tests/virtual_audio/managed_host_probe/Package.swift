// swift-tools-version: 6.0
import PackageDescription

// Independent SwiftPM probe for the 015 integration gate. It links the real
// VirtualCaptureHostSupport controller and BoundedPipeWriter, but injects a
// deterministic non-HAL FakeProvider so the full Swift controller/resampler/
// encoder path runs without capture permission or a device.
let package = Package(
    name: "ManagedHostProbe",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(path: "../../../platforms/macos/VirtualAudioInput"),
        .package(path: "../../../platforms/macos/ProcessTapCapture"),
    ],
    targets: [
        .executableTarget(
            name: "ManagedHostProbe",
            dependencies: [
                .product(name: "VirtualCaptureHostSupport", package: "VirtualAudioInput"),
                .product(name: "VirtualAudioInput", package: "VirtualAudioInput"),
                .product(name: "TapCaptureHostSupport", package: "ProcessTapCapture"),
            ]
        )
    ]
)
