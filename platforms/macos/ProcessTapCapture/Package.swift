// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProcessTapCapture",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "ProcessTapCapture", targets: ["ProcessTapCapture"]),
        .library(name: "CaptureRing", targets: ["CaptureRing"]),
        .executable(name: "tap-capture-probe", targets: ["TapCaptureProbe"]),
        .executable(name: "tap-capture-host", targets: ["TapCaptureHost"])
    ],
    targets: [
        .target(name: "CaptureRing", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("proc")]),
        .target(name: "ProcessTapCapture", dependencies: ["CaptureRing"]),
        .executableTarget(name: "TapCaptureProbe", dependencies: ["ProcessTapCapture"]),
        .target(name: "TapCaptureHostSupport", dependencies: ["ProcessTapCapture"]),
        .executableTarget(name: "TapCaptureHost", dependencies: ["TapCaptureHostSupport"]),
        .testTarget(name: "ProcessTapCaptureTests", dependencies: ["ProcessTapCapture", "CaptureRing"]),
        .testTarget(name: "TapCaptureHostTests", dependencies: ["TapCaptureHostSupport", "ProcessTapCapture"])
    ],
    cLanguageStandard: .c11
)
