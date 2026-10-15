import AppKit
import HerdrVoiceCore
import SwiftUI
import VoiceEngine

/// `VoiceCompanion --self-test`: builds what a launch builds except the voice session (no microphone, no network,
/// no API key), from a scratch configuration: shows the orb, grows it into the phone and back, renders every screen,
/// pushes a typed turn through routing, runs two read-only Mac actions, and checks the new hire: factory state, a
/// greeting that names its harnesses and asks for a first task, and self-changes that stop for the user's yes and
/// change nothing without it. Then drives the session controls and tap-to-talk on a session it never starts. Prints
/// each check; exits 0 only if all pass.
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

    let window = PhoneWindow(model: controller.phone, content: PhoneRoot(controller: controller, model: controller.phone,
                                                                         live: controller.live, device: controller.device))
    controller.phoneWindow = window
    window.showOrb()
    let orbFrame = window.panel.frame
    let corner = (NSScreen.screens.first { $0.frame.intersects(orbFrame) } ?? NSScreen.main)?.visibleFrame ?? .zero
    check("the orb shows in the screen's bottom-right corner",
          window.panel.isVisible && orbFrame.width < 200 && abs(orbFrame.maxX - corner.maxX) < 60
              && abs(orbFrame.minY - corner.minY) < 60, "\(Int(orbFrame.width))×\(Int(orbFrame.height))")

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

    checkPhone(controller, window, check)

    let session = checkSessionControls(controller, check)
    checkActivation(controller, session, check)
    checkVoiceControl(controller, session, gate, check)

    window.panel.orderOut(nil)
    print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
    return failures == 0 ? 0 : 1
}

/// Mute, Pause, Stop speaking and Connect/Disconnect, driven through the controller on a session that is never
/// started: no microphone, and no network (Local without its runtime stays closed, so Connect and a typed message
/// only clear the disconnect and leave the session to open once the runtime is up).
@MainActor private func checkSessionControls(_ controller: CompanionController,
                                             _ check: (String, Bool, String) -> Void) -> Realtime {
    func titles() -> [String] { controller.controlChoices().map(\.title) }
    func enabled(_ title: String) -> Bool? { controller.controlChoices().first { $0.title == title }?.enabled }
    let state = { controller.chat.controls.state }

    let none = controller.controlChoices()
    check("without a session the controls are listed and off",
          none.map(\.title).contains("Mute") && !none.contains { $0.enabled }, none.map(\.title).joined(separator: ", "))

    setenv("HERDR_VOICE_ECHO_CANCEL", "0", 1) // the unstarted engine's voice processing is left alone
    let session = Realtime(provider: .local, key: "", voice: "", host: controller.registry,
                           instructions: controller.registry.instructions, greeting: controller.registry.greeting)
    controller.attach(session)
    session.onUserTurn = nil // a typed turn below would be routed, and the router may call Jev

    let tiles = controller.quickTiles.map(\.id)
    check("the shade has a tile for the mic, pause, the session, activation and stop speaking",
          ["mic", "pause", "session", "activation", "stop"].allSatisfy(tiles.contains), tiles.joined(separator: ", "))

    let orb = titles(), menuBar = controller.statusMenuItems().map(\.title)
    let expected = ["Voice: Offline", "Mute", "Pause", SessionControls.stopTitle, "Connect"]
    check("the orb's right-click menu and the menu bar have every control",
          expected.allSatisfy(orb.contains) && expected.allSatisfy(menuBar.contains), orb.joined(separator: ", "))
    check("Stop speaking is off while nothing is said", enabled(SessionControls.stopTitle) == false, "")

    // The 0.2.1 bug: one Mute press logged "muted" then "listening" and the next sentence was heard. One press, and
    // the same press delivered again (a double click, the menu and ⌥⌘M together), must leave it muted, mic closed.
    let mute = controller.chat.controls.mutePress
    controller.press(mute)
    let mutedOnce = session.muted && !session.micOpen
    controller.press(mute)
    let muted = mutedOnce && session.muted && !session.micOpen && state() == "Muted" && titles().contains("Unmute")
        && !controller.chat.controls.listening
    check("one Mute press leaves the session muted and the mic gate closed, even delivered twice", muted, state())
    controller.hotkeyMute() // ⌥⌘M right after: the same press again as far as anyone meant it
    check("⌥⌘M a moment after a Mute press counts once", session.muted && !session.micOpen, state())
    controller.press(controller.chat.controls.mutePress)
    check("Unmute opens the mic again", !session.muted && session.micOpen, state())

    let pause = controller.chat.controls.pausePress
    controller.press(pause)
    controller.press(pause)
    let paused = session.paused && !session.micOpen && state() == "Paused" && titles().contains("Resume")
        && Activity.mood(controls: controller.chat.controls, loading: false, agentsWorking: false, micQuiet: true) == .muted
    controller.press(controller.chat.controls.pausePress)
    check("Pause holds (muted mood), even pressed twice, and Resume lets go", paused && !session.paused && session.micOpen,
          state())

    let idleOffersDisconnect = state() == "Idle" && titles().contains("Disconnect") // it would reopen on speech
    let disconnect = controller.chat.controls.connectPress
    controller.press(disconnect)
    controller.press(disconnect)
    let disconnected = idleOffersDisconnect && session.disconnectedByUser && state() == "Disconnected"
        && titles().contains("Connect") && !session.micOpen
        && Activity.mood(controls: controller.chat.controls, loading: false, agentsWorking: false, micQuiet: true) == .offline
    session.toggleMute() // the engine's toggle (the plugin's hotkey) mutes, and doesn't reopen what the user closed
    let stays = session.disconnectedByUser && session.muted && session.status == .disconnected
    session.toggleMute()
    controller.press(controller.chat.controls.connectPress)
    check("Disconnect stays closed (offline mood), even pressed twice, until Connect",
          disconnected && stays && !session.disconnectedByUser, state())

    session.disconnect()
    session.pause()
    controller.send("are you there")
    check("a typed message ends a disconnect and a pause",
          !session.disconnectedByUser && !session.paused && controller.chat.lines.contains { $0.text == "are you there" },
          state())
    return session
}

/// Tap-to-talk on the same never-started session, with made-up times: the key's buffering and a chord's discard, a
/// tap, speech and the cooldown, her reply and the follow-up window running out, a double tap and Esc.
@MainActor private func checkActivation(_ controller: CompanionController, _ session: Realtime,
                                        _ check: (String, Bool, String) -> Void) {
    session.deferReplies = true
    session.setStandby(true)
    controller.turns = TurnTaking(timing: .init(cooldown: 0.5, followUp: 8))
    let t = Date()
    func at(_ seconds: TimeInterval) -> Date { t.addingTimeInterval(seconds) }
    func phase() -> String { "\(controller.conversation)" }

    controller.activation(.keyDown, at: at(0))
    let buffering = !session.standby && session.buffering
    controller.activation(.otherKey, at: at(0.1)) // ⌘C
    controller.activation(.keyUp, at: at(0.2))
    check("⌘C never activates: the key only buffered, nothing connected or showed, and it's dropped",
          buffering && session.standby && !session.buffering && controller.conversation == .idle
              && !controller.phone.expanded, phase())

    controller.activation(.keyDown, at: at(1))
    controller.activation(.keyUp, at: at(1.1))
    check("a tap of the key alone opens a conversation and the mic",
          controller.conversation == .listening(heard: false, since: at(1.1)) && !session.standby && session.micOpen,
          phase())

    controller.activation(.speechStarted, at: at(1.5))
    controller.activation(.speechStopped, at: at(3))
    let cooling = controller.turns.cooldownProgress(at: at(3.25)) == 0.5
    controller.activation(.speechStarted, at: at(3.2))
    let resumed = controller.conversation == .listening(heard: true, since: at(3.2))
    controller.activation(.speechStopped, at: at(4))
    controller.activation(.tick, at: at(4.5))
    check("speech, a cooldown that resumed speech cancels, then the turn is submitted",
          cooling && resumed && controller.conversation == .replying(since: at(4.5)), phase())

    controller.activation(.assistant(busy: true), at: at(5))
    controller.activation(.assistant(busy: false), at: at(7))
    let following = controller.turns.followUpRemaining(at: at(9)) == 0.75 && !session.standby
    controller.activation(.tick, at: at(15))
    check("after her reply the follow-up window runs out and the session goes back to standby",
          following && controller.conversation == .idle && session.standby && controller.chat.controls.state != "Connected",
          controller.chat.controls.state)

    controller.activation(.tap, at: at(20))
    controller.activation(.tap, at: at(20.2))
    let handsFree = controller.handsFree
    controller.escape()
    check("a double tap is hands-free; Esc ends it and closes",
          handsFree && !controller.handsFree && controller.conversation == .idle && session.standby, phase())
}

/// The orb grows into the phone and back in the real window, and every screen (lock, home, Messages, Settings,
/// Skills, an app, the shade), the orb and a frame of the morph render to images with something drawn.
@MainActor private func checkPhone(_ controller: CompanionController, _ window: PhoneWindow,
                                   _ check: (String, Bool, String) -> Void) {
    controller.openPhone(.home, activate: false)
    RunLoop.main.run(until: Date().addingTimeInterval(1)) // the spring settles
    let open = window.panel.frame
    check("the orb grows into the phone, anchored at its corner",
          controller.phone.expanded && controller.phone.morph == 1 && open.height >= PhoneWindow.phoneSize.height
              && window.panel.canBecomeKey, "\(Int(open.width))×\(Int(open.height))")
    for name in ["lock", "home", "messages", "settings", "skills"] {
        controller.phone.go(PhoneScreen.named[name] ?? .home)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    controller.collapsePhone()
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    check("the phone collapses back into the orb", !controller.phone.expanded && controller.phone.morph == 0
          && window.panel.frame.height < 200, "\(Int(window.panel.frame.height)) high")

    var drawn: [String] = [], blank: [String] = []
    for shot in PhoneRender.shots(appID: "harness.mac") {
        if let image = PhoneRender.image(shot, controller: controller), PhoneRender.looksDrawn(image) {
            drawn.append(shot.name)
        } else {
            blank.append(shot.name)
        }
    }
    controller.phone.morph = 0
    controller.phone.expanded = false
    controller.phone.shadeOpen = false
    check("every screen renders: lock, home, messages, settings, skills, an app, the shade, the orb and the morph",
          blank.isEmpty, blank.isEmpty ? drawn.joined(separator: ", ") : "blank: " + blank.joined(separator: ", "))
}

/// Her own app by voice: the companion harness's tools change settings as your edits (by voice), drive the
/// session and the phone, and stop for a spoken yes where they raise her power.
@MainActor private func checkVoiceControl(_ controller: CompanionController, _ session: Realtime, _ gate: ConfirmGate,
                                          _ check: (String, Bool, String) -> Void) {
    let registry = controller.registry
    func say(_ tool: String, _ arguments: [String: Any] = [:]) -> String {
        let out = registry.call(tool, arguments: json(arguments), userInitiated: true).output
        RunLoop.main.run(until: Date().addingTimeInterval(0.05)) // the settle reaches the controller
        return out
    }
    check("her app's controls are tools she has from the first turn",
          ["set_activation", "show_screen", "mute_mic", "set_model"].allSatisfy(registry.activeTools.names.contains),
          "\(registry.activeTools.names.count) tools")

    let changes = registry.changes.count
    let followUp = say("set_follow_up", ["seconds": 12])
    check("a setting said aloud applies at once, as your edit by voice",
          followUp.hasPrefix("Done") && controller.settings.followUpSeconds == 12 && controller.turns.timing.followUp == 12
              && registry.changes.count == changes + 1 && registry.changes.last?.summary.hasSuffix("(by voice)") == true,
          followUp)

    _ = say("show_screen", ["screen": "settings"])
    let shown = controller.phone.expanded && controller.phone.screen == .settings
    _ = say("collapse_phone")
    check("she shows a screen and puts the phone away by voice", shown && !controller.phone.expanded, "")

    _ = say("mute_mic", ["on": true])
    let muted = session.muted && !session.micOpen
    _ = say("mute_mic", ["on": false])
    _ = say("pause_session")
    controller.runDeferredPress(at: Date()) // she has finished saying so
    let paused = session.paused
    _ = say("resume_session")
    check("mute, pause and resume by voice reach the session", muted && paused && !session.paused && !session.muted, "")

    let model = say("set_model", ["provider": "openai"])
    gate.heard("no")
    let shell = say("set_shell", ["on": true])
    gate.heard("no")
    check("switching the model or the shell on by voice still needs your spoken yes",
          model.hasPrefix("CONFIRMATION REQUIRED") && shell.hasPrefix("CONFIRMATION REQUIRED")
              && controller.settings.provider == nil && registry.tree["harness.shell"]?.disabled == true, model)
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
