// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "herdr-voice",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HerdrVoiceCore"),
        .executableTarget(name: "herdr-voice", dependencies: ["HerdrVoiceCore"]),
        .testTarget(name: "HerdrVoiceTests", dependencies: ["HerdrVoiceCore"]),
    ]
)
