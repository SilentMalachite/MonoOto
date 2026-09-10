// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MonoOto",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "MonoOtoCore", targets: ["MonoOtoCore"]),
        .library(name: "MonoOtoAudio", targets: ["MonoOtoAudio"]),
    ],
    targets: [
        .target(name: "MonoOtoRealtime"),
        .target(name: "MonoOtoRealtimeTestSupport", dependencies: ["MonoOtoRealtime"],
                path: "Tests/MonoOtoRealtimeTestSupport"),
        .testTarget(name: "MonoOtoRealtimeTests", dependencies: ["MonoOtoRealtime", "MonoOtoRealtimeTestSupport"]),
        .target(name: "MonoOtoCore"),
        .target(name: "MonoOtoAudio", dependencies: ["MonoOtoCore"]),
        .testTarget(name: "MonoOtoCoreTests", dependencies: ["MonoOtoCore"]),
        .testTarget(name: "MonoOtoAudioTests", dependencies: ["MonoOtoAudio", "MonoOtoCore"]),
    ],
    cLanguageStandard: .c11
)
