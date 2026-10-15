// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "herdr-voice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "herdr-voice", targets: ["herdr-voice"]),
        .executable(name: "VoiceCompanion", targets: ["VoiceCompanion"]),
    ],
    targets: [
        /// Testable logic: wires, tools, harnesses, skills, routing. No audio or UI.
        .target(name: "HerdrVoiceCore"),
        /// The live voice session, audio, the orb and hotkeys, shared by the Herdr plugin and the companion app.
        .target(name: "VoiceEngine", dependencies: ["HerdrVoiceCore"]),
        /// The Herdr plugin: a voice pane driving Herdr.
        .executableTarget(name: "herdr-voice", dependencies: ["HerdrVoiceCore", "VoiceEngine"]),
        /// The standalone companion: a floating chat that controls the Mac through skills.
        .executableTarget(name: "VoiceCompanion", dependencies: ["HerdrVoiceCore", "VoiceEngine"]),
        .testTarget(name: "HerdrVoiceTests", dependencies: ["HerdrVoiceCore"]),
        /// The live session driven end to end with a fake socket and made-up mic chunks: no microphone, no network.
        .testTarget(name: "VoiceEngineTests", dependencies: ["VoiceEngine", "HerdrVoiceCore"]),
    ]
)
