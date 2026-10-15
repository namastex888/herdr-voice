import AppKit
import HerdrVoiceCore

/// `VoiceCompanion --self-test`: builds what a launch builds except the voice session (no microphone, no network,
/// no API key), opens the chat panel, pushes a typed turn through routing and the registry, runs two read-only Mac
/// actions, and checks that learning a skill stops for a spoken yes. Prints each check; exits 0 only if all pass.
@MainActor func runSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "✔" : "✘") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        if !ok { failures += 1 }
    }

    print("Voice Companion self-test (\(Bundle.main.bundleIdentifier ?? "no bundle"), "
          + "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))")
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vc-selftest-\(UUID().uuidString)")
    let controller = CompanionController(store: SkillStore(directory: scratch))
    let registry = controller.registry

    let window = ChatWindow(content: CompanionView(controller: controller, chat: controller.chat, settings: controller.settings))
    window.show()
    check("chat panel shows and can take typing", window.isVisible && window.panel.canBecomeKey)

    let skills = registry.skills.map(\.id)
    check("built-in Mac skills are available", ["mac-apps", "mac-system", "mac-shortcuts"].allSatisfy(skills.contains),
          skills.joined(separator: ", "))

    let decision = WordRouter().decide("open safari for me", skills: registry.skills)
    check("a typed turn routes to the apps skill", decision?.skill == "mac-apps", "\(decision?.skill ?? "none")")
    if let decision { registry.activate(decision.skill) }
    check("the routed skill's tools are offered", registry.activeTools.names.contains("open_app"),
          registry.activeTools.names.joined(separator: ", "))

    let catalog = registry.call("list_skills", arguments: "{}", userInitiated: true).output
    check("list_skills runs through the registry", catalog.contains("mac-apps"))

    let apps = registry.call("list_apps", arguments: "{}", userInitiated: true).output
    check("list_apps reads the running apps", !apps.hasPrefix("error") && !apps.isEmpty, String(apps.prefix(80)))

    let volume = registry.call("get_volume", arguments: "{}", userInitiated: true).output
    check("get_volume reads the output volume", !volume.hasPrefix("error"), volume)

    let learn = registry.call("learn_skill", arguments: #"{"title":"Self test","summary":"s","steps":[{"action":"list_apps"}]}"#,
                              userInitiated: true).output
    check("learning a skill waits for a spoken yes", learn.hasPrefix("CONFIRMATION REQUIRED") && registry.learned.isEmpty)

    let instructions = CompanionVoice.instructions(catalog: registry.catalog, herdr: false)
    check("the voice is told its skills", instructions.contains("mac-apps") && instructions.contains("use_skill"))

    window.panel.orderOut(nil)
    try? FileManager.default.removeItem(at: scratch)
    print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
    return failures == 0 ? 0 : 1
}
