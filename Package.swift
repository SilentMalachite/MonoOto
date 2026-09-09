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
        .target(name: "MonoOtoCore"),
        .target(name: "MonoOtoAudio", dependencies: ["MonoOtoCore"]),
        .testTarget(name: "MonoOtoCoreTests", dependencies: ["MonoOtoCore"]),
        .testTarget(name: "MonoOtoAudioTests", dependencies: ["MonoOtoAudio", "MonoOtoCore"]),
    ]
)
