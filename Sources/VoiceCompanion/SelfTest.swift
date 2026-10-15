import AppKit
import HerdrVoiceCore
import SwiftUI
import VoiceEngine

/// `VoiceCompanion --self-test`: builds what a launch builds except the voice session (no microphone, no network,
/// no API key), from a scratch configuration, opens the chat panel and each tab, pushes a typed turn through routing,
/// runs two read-only Mac actions, and checks the new hire: factory state, a greeting that names its harnesses and
/// asks for a first task, and self-changes that stop for the user's yes and change nothing without it. Then drives the
/// session controls on a session it never starts. Prints each check; exits 0 only if all pass.
@MainActor func runSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "✔" : "✘") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        if !ok { failures += 1 }
    }

    print("Voice Companion self-test (\(Bundle.main.bundleIdentifier ?? "no bundle"), "
          + "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))")
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vc-selftest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    // Its own gate, answering at once: the user's "no" below clears each question before the next is asked.
    let gate = ConfirmGate(minDelay: 0, wait: 0)
    let controller = CompanionController(store: CompanionStore(directory: scratch), legacyDefaults: nil, gate: gate)
    let registry = controller.registry

    let window = ChatWindow(content: CompanionView(controller: controller, chat: controller.chat, keys: controller.keys))
    window.show()
    check("chat panel shows and can take typing", window.isVisible && window.panel.canBecomeKey)

    // Factory state: the harnesses, identity, empty memory and default settings, and nothing learned.
    check("a new hire starts from the factory configuration", registry.tree == .factory)
    check("a new hire knows no skills", registry.skills.isEmpty && registry.changes.isEmpty,
          registry.skills.map(\.id).joined(separator: ", "))
    let profile = registry.profile
    check("the greeting names her harnesses and asks for a first task",
          profile.isNewHire && profile.controls.contains { $0.entryID == "harness.mac" }
              && registry.greeting.contains(profile.controlNames) && registry.greeting.contains("first task"),
          profile.controlNames)
    check("the Mac controls are loaded from the first turn", registry.activeTools.names.contains("open_app"),
          "\(registry.activeTools.names.count) tools")
    check("the voice is told its controls and how to learn",
          registry.instructions.contains("harness.mac") && registry.instructions.contains("learn_skill"))

    let decision = WordRouter().decide("open safari for me", options: registry.routeOptions)
    check("a typed turn routes to the Mac controls", decision?.skill == "harness.mac", "\(decision?.skill ?? "none")")

    let me = registry.call("describe_self", arguments: "{}", userInitiated: true).output
    check("describe_self runs through the registry", me.contains("harness.mac") && me.contains("Skills: none yet"))

    let apps = registry.call("list_apps", arguments: "{}", userInitiated: true).output
    check("list_apps reads the running apps", !apps.hasPrefix("error") && !apps.isEmpty, String(apps.prefix(80)))

    let volume = registry.call("get_volume", arguments: "{}", userInitiated: true).output
    check("get_volume reads the output volume", !volume.hasPrefix("error"), volume)

    // Each way she changes herself asks first, and a confirmed call without the user's yes does nothing.
    let attempts: [(tool: String, arguments: [String: Any])] = [
        ("propose_change", ["summary": "Remember standup", "changes": [
            ["op": "append", "path": "memory.facts", "value": "Standup is at 10:00"],
            ["op": "set", "path": "identity.personality", "value": "brisk"]]]),
        ("remember", ["fact": "Standup is at 10:00"]),
        ("learn_skill", ["title": "Self test", "summary": "Lists the apps", "steps": [["action": "list_apps"]],
                         "playbook": "Say how many apps are open."]),
    ]
    for attempt in attempts {
        let before = (registry.tree, registry.changes, registry.metrics)
        let asked = registry.call(attempt.tool, arguments: json(attempt.arguments), userInitiated: true).output
        gate.heard("no, leave it")
        var confirmed = attempt.arguments
        confirmed["confirmed"] = true
        let refused = registry.call(attempt.tool, arguments: json(confirmed), userInitiated: true).output
        let unchanged = registry.tree == before.0 && registry.changes == before.1 && registry.metrics == before.2
        check("\(attempt.tool) stops at CONFIRMATION REQUIRED and changes nothing without a yes",
              asked.hasPrefix("CONFIRMATION REQUIRED") && refused.hasPrefix("NOT DONE") && unchanged,
              unchanged ? ChatModel.question(in: asked) ?? String(asked.prefix(80)) : "the configuration changed")
    }
    check("the chat shows her question whole",
          ChatModel.question(in: registry.call("remember", arguments: #"{"fact":"Lunch is at noon"}"#,
                                               userInitiated: true).output) == "may I remember that Lunch is at noon")
    gate.heard("no")

    // The human's own edits apply at once, are logged as theirs, and revert.
    controller.setIdentity("name", "Robin")
    controller.addFact("Standup is at 10:00")
    let edited = registry.tree["identity"]?.config["name"]?.string == "Robin" && registry.changes.count == 2
        && registry.changes.allSatisfy { $0.by == .user }
    if let last = registry.changes.last { controller.revert(last.id) }
    let reverted = registry.tree["memory"] == ConfigTree.factory["memory"]
    controller.resetToNewHire()
    check("your edits apply, revert, and reset to a new hire", edited && reverted && registry.tree == .factory,
          controller.notice)

    for tab in CompanionTab.allCases {
        controller.tab = tab
        RunLoop.main.run(until: Date().addingTimeInterval(0.1)) // a beat for SwiftUI to lay the tab out
    }
    check("each tab opens", window.isVisible && controller.harnesses.contains { $0.id == "harness.mac" })

    checkSessionControls(controller, check)

    window.panel.orderOut(nil)
    print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
    return failures == 0 ? 0 : 1
}

/// Mute, Pause, Stop speaking and Connect/Disconnect, driven through the controller on a session that is never
/// started: no microphone, and no network (Local without its runtime stays closed, so Connect and a typed message
/// only clear the disconnect and leave the session to open once the runtime is up).
@MainActor private func checkSessionControls(_ controller: CompanionController,
                                             _ check: (String, Bool, String) -> Void) {
    func titles() -> [String] { controller.orbMenu().map(\.title) }
    func enabled(_ title: String) -> Bool? { controller.orbMenu().first { $0.title == title }?.enabled }
    let state = { controller.chat.controls.state }

    let none = controller.controlChoices()
    check("without a session the controls are listed and off",
          none.map(\.title).contains("Mute") && !none.contains { $0.enabled }, none.map(\.title).joined(separator: ", "))

    setenv("HERDR_VOICE_ECHO_CANCEL", "0", 1) // the unstarted engine's voice processing is left alone
    let session = Realtime(provider: .local, key: "", voice: "", host: controller.registry,
                           instructions: controller.registry.instructions, greeting: controller.registry.greeting)
    controller.attach(session)
    session.onUserTurn = nil // a typed turn below would be routed, and the router may call Jev

    let bar = NSHostingView(rootView: ControlBar(controller: controller, chat: controller.chat))
    bar.layoutSubtreeIfNeeded()
    let size = bar.fittingSize
    check("the control bar renders", size.width > 0 && size.height > 0, "\(Int(size.width))×\(Int(size.height))")

    let orb = titles(), menuBar = controller.statusMenuItems().map(\.title)
    let expected = ["Voice: Offline", "Mute", "Pause", SessionControls.stopTitle, "Connect"]
    check("the orb's menu and the menu bar have every control",
          expected.allSatisfy(orb.contains) && expected.allSatisfy(menuBar.contains), orb.joined(separator: ", "))
    check("Stop speaking is off while nothing is said", enabled(SessionControls.stopTitle) == false, "")

    controller.toggleMute()
    let muted = session.muted && state() == "Muted" && titles().contains("Unmute") && !controller.chat.controls.listening
    controller.toggleMute()
    check("Mute mutes even while the session is closed, and unmutes", muted && !session.muted, state())

    controller.togglePause()
    let paused = session.paused && state() == "Paused" && titles().contains("Resume")
        && Activity.mood(controls: controller.chat.controls, loading: false, agentsWorking: false, micQuiet: true) == .muted
    controller.togglePause()
    check("Pause holds (muted mood) and Resume lets go", paused && !session.paused, state())

    let idleOffersDisconnect = state() == "Idle" && titles().contains("Disconnect") // it would reopen on speech
    controller.toggleConnection()
    let disconnected = idleOffersDisconnect && session.disconnectedByUser && state() == "Disconnected"
        && titles().contains("Connect")
        && Activity.mood(controls: controller.chat.controls, loading: false, agentsWorking: false, micQuiet: true) == .offline
    session.toggleMute() // the engine's toggle (the plugin's hotkey) mutes, and doesn't reopen what the user closed
    let stays = session.disconnectedByUser && session.muted && session.status == .disconnected
    session.toggleMute()
    controller.toggleConnection()
    check("Disconnect stays closed (offline mood) until Connect", disconnected && stays && !session.disconnectedByUser,
          state())

    session.disconnect()
    controller.togglePause()
    controller.send("are you there")
    check("a typed message ends a disconnect and a pause",
          !session.disconnectedByUser && !session.paused && controller.chat.lines.contains { $0.text == "are you there" },
          state())
}

private func json(_ object: [String: Any]) -> String {
    (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
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
