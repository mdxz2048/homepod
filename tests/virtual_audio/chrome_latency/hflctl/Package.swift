// swift-tools-version: 6.0
import PackageDescription

/// hflctl: read-only HAL status + guarded, explicitly-scoped latency control for
/// the HomePod Flow Audio virtual device (default UID
/// `com.homepodflow.virtual-audio.surround71.v1`).
///
/// The library target holds pure arithmetic so it can be tested without any
/// CoreAudio device or permission. The C support target resolves a selector
/// that the Swift CoreAudio overlay does not re-export, exactly like the
/// production HALInputConstants target.
let package = Package(
    name: "HFLatencyControl",
    platforms: [.macOS("14.2")],
    targets: [
        .target(
            name: "HFLatencyControlSupport",
            path: "Sources/HFLatencyControlSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "HFLatencyControlCore",
            path: "Sources/HFLatencyControlCore"
        ),
        .executableTarget(
            name: "hflctl",
            dependencies: ["HFLatencyControlCore", "HFLatencyControlSupport"],
            path: "Sources/hflctl"
        ),
        .testTarget(
            name: "HFLatencyControlCoreTests",
            dependencies: ["HFLatencyControlCore"],
            path: "Tests/HFLatencyControlCoreTests"
        ),
    ]
)
