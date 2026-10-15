import AppKit
import HerdrVoiceCore

/// `VoiceCompanion --self-test`: builds what a launch builds except the voice session (no microphone, no network,
/// no API key), from a scratch configuration, opens the chat panel, pushes a typed turn through routing and the
/// registry, runs two read-only Mac actions, and checks that the new hire has no skills and that learning one stops
/// for a spoken yes. Prints each check; exits 0 only if all pass.
@MainActor func runSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "✔" : "✘") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        if !ok { failures += 1 }
    }

    print("Voice Companion self-test (\(Bundle.main.bundleIdentifier ?? "no bundle"), "
          + "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))")
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vc-selftest-\(UUID().uuidString)")
    let controller = CompanionController(store: CompanionStore(directory: scratch), legacyDefaults: nil)
    let registry = controller.registry

    let window = ChatWindow(content: CompanionView(controller: controller, chat: controller.chat, settings: controller.settings))
    window.show()
    check("chat panel shows and can take typing", window.isVisible && window.panel.canBecomeKey)

    check("a new hire knows no skills", registry.skills.isEmpty, registry.skills.map(\.id).joined(separator: ", "))
    check("the Mac controls are loaded from the first turn", registry.activeTools.names.contains("open_app"),
          registry.activeTools.names.joined(separator: ", "))
    check("the greeting asks for a first task", registry.greeting.contains("first task") && registry.greeting.contains("Mac"))

    let decision = WordRouter().decide("open safari for me", options: registry.routeOptions)
    check("a typed turn routes to the Mac controls", decision?.skill == "harness.mac", "\(decision?.skill ?? "none")")

    let me = registry.call("describe_self", arguments: "{}", userInitiated: true).output
    check("describe_self runs through the registry", me.contains("harness.mac") && me.contains("Skills: none yet"))

    let apps = registry.call("list_apps", arguments: "{}", userInitiated: true).output
    check("list_apps reads the running apps", !apps.hasPrefix("error") && !apps.isEmpty, String(apps.prefix(80)))

    let volume = registry.call("get_volume", arguments: "{}", userInitiated: true).output
    check("get_volume reads the output volume", !volume.hasPrefix("error"), volume)

    let learn = registry.call("learn_skill", arguments: #"{"title":"Self test","summary":"s","steps":[{"action":"list_apps"}]}"#,
                              userInitiated: true).output
    check("learning a skill waits for a spoken yes", learn.hasPrefix("CONFIRMATION REQUIRED") && registry.skills.isEmpty)

    check("the voice is told its controls and how to learn",
          registry.instructions.contains("harness.mac") && registry.instructions.contains("learn_skill"))

    window.panel.orderOut(nil)
    try? FileManager.default.removeItem(at: scratch)
    print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
    return failures == 0 ? 0 : 1
}

/// `VoiceCompanion --dump-tools <file>`: writes every tool the registry offers, as the wires send them, so the schemas
/// can be checked against a provider without starting a session.
@MainActor func dumpTools(to path: String) -> Int32 {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vc-dump-\(UUID().uuidString)")
    let registry = CompanionController(store: CompanionStore(directory: scratch), legacyDefaults: nil).registry
    let tools = registry.tools.definitions
    guard let data = try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys]),
          (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return 1 }
    print("wrote \(tools.count) tools to \(path)")
    return 0
}
