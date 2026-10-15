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
    let controller = CompanionController(store: CompanionStore(directory: scratch), legacyDefaults: nil, gate: gate,
                                         home: VoxHome(root: scratch.appendingPathComponent("vox")))
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

    let session = checkSessionControls(controller, check)
    checkActivation(controller, session, check)
    checkVoiceControl(controller, session, gate, check)
    checkVoiceMode(controller, session, gate, check)
    checkMetrics(controller, session, check)
    checkVoiceChat(controller, check)
    checkPhone(controller, window, check)

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
    for name in ["lock", "home", "chat", "conversations", "settings", "skills"] {
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
    check("every screen renders: " + PhoneRender.shots(appID: "harness.mac").map(\.name).joined(separator: ", "),
          blank.isEmpty, blank.isEmpty ? "\(drawn.count) drawn" : "blank: " + blank.joined(separator: ", "))
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

/// The day's numbers: one scripted OpenAI turn, fed through the session's own callbacks (speech, transcript, a tool,
/// usage, her audio), lands in the aggregate with its latency, action, talk time and token cost, and in metrics.json.
@MainActor private func checkMetrics(_ controller: CompanionController, _ session: Realtime,
                                     _ check: (String, Bool, String) -> Void) {
    let numbers = controller.numbers, provider = numbers.provider
    numbers.flush()
    let before = numbers.today
    numbers.provider = .openai
    session.onSpeech?(true)
    session.onSpeech?(false)
    session.onEvent?(.you("which agents are running"))
    session.onEvent?(.toolCall(name: "list_agents", arguments: "{}"))
    session.onEvent?(.toolResult(name: "list_agents", output: "[]"))
    session.onUsage?(RealtimeUsage(inputAudioTokens: 1000, outputAudioTokens: 500))
    session.audio.onPlayed?(syntheticSpeech(seconds: 0.5, seed: 6), "metrics-1")
    session.onEvent?(.voice("None are running right now."))
    numbers.frame(at: Date().addingTimeInterval(3), connected: false, busy: false)
    numbers.frame(at: Date().addingTimeInterval(5), connected: false, busy: false)
    numbers.flush()
    numbers.drain()
    let after = numbers.today, saved = MetricsLedger.load(controller.home.metrics).day(Date())
    let cost = (after.cost["openai"] ?? 0) - (before.cost["openai"] ?? 0)
    check("a turn lands in the day's numbers: turns, actions, latency, her talk time and its token cost, in metrics.json",
          after.turns == before.turns + 1 && after.actions == before.actions + 1
              && after.latencyCount == before.latencyCount + 1 && after.voxTalkSeconds > before.voxTalkSeconds
              && abs(cost - (1000 * 32 + 500 * 64) / 1_000_000) < 1e-9 && saved == after,
          String(format: "%d turns, $%.4f, %.0f ms", after.turns, after.totalCost, after.averageLatencyMs ?? -1))
    numbers.provider = provider
}

/// The voice chat: a spoken exchange becomes two voice notes with transcripts, saved as WAV files and a transcript
/// under the (scratch) conversations folder; nothing muted or paused is kept; one conversation or all can be deleted.
@MainActor private func checkVoiceChat(_ controller: CompanionController, _ check: (String, Bool, String) -> Void) {
    let recorder = controller.recorder, store = recorder.store
    recorder.end() // the typed turns of the checks above were a conversation of their own
    recorder.deleteAll()
    recorder.drain()
    stageVoiceNotes(controller)
    let saved = store.list()
    let transcript = saved.first
    let files = transcript.map { t in t.clips.compactMap { store.audioURL($0, in: t.id) } } ?? []
    check("a spoken exchange is kept as voice notes: your audio, hers, both transcripts and a typed turn",
          saved.count == 1 && transcript?.clips.map(\.side) == [.user, .vox, .user]
              && transcript?.clips.map(\.text) == ["Open Safari and set the volume to 30",
                                                   "Done: Safari's open and the volume is at 30.", "Thanks!"]
              && files.count == 2 && files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
              && store.root.path.hasPrefix(FileManager.default.temporaryDirectory.path),
          transcript.map { "\($0.id): \($0.clips.count) notes, \(files.count) audio files" } ?? "nothing saved")

    controller.press(.mute(true))
    recorder.mic(syntheticSpeech(seconds: 0.5, seed: 3))
    controller.press(.mute(false))
    controller.press(.pause(true))
    recorder.mic(syntheticSpeech(seconds: 0.5, seed: 4))
    controller.press(.pause(false))
    check("muted or paused, the mic is never kept", recorder.clips.count == 3 && recorder.clips.last?.typed == true,
          "\(recorder.clips.count) notes")

    recorder.mic(syntheticSpeech(seconds: 0.4, seed: 5))
    recorder.heard(.you("A second conversation"))
    recorder.end()
    recorder.drain()
    let two = store.list().count
    if let first = transcript?.id { recorder.delete(first) }
    recorder.drain()
    let one = store.list().count
    recorder.deleteAll()
    recorder.drain()
    check("conversations are kept until you delete one, or all", two == 2 && one == 1 && store.list().isEmpty,
          "\(two) → \(one) → \(store.list().count)")
    stageVoiceNotes(controller) // for the screens below
}

/// Voice mode: a tap lights the orb without the phone; the phone rises for what she shows or asks, and goes back
/// into the orb by itself (a shown result a few seconds after she's quiet, the conversation's end, another app taking
/// focus), never while her question waits for a yes; the gesture bar and Esc put it away too. Fake clock throughout.
@MainActor private func checkVoiceMode(_ controller: CompanionController, _ session: Realtime, _ gate: ConfirmGate,
                                       _ check: (String, Bool, String) -> Void) {
    let registry = controller.registry
    let t = Date()
    func at(_ seconds: TimeInterval) -> Date { t.addingTimeInterval(seconds) }
    func show(_ screen: String) { _ = registry.call("show_screen", arguments: json(["screen": screen]), userInitiated: true) }
    controller.collapsePhone()
    controller.activation(.reset)

    controller.activation(.tap, at: at(0))
    controller.updateLive(at: at(0))
    check("a tap lights the orb's listening glow and leaves the phone down",
          !controller.phone.expanded && controller.live.frame.listening && !controller.conversation.isIdle,
          "\(controller.conversation)")

    show("home")
    let shown = controller.phone.expanded && controller.phoneReason == .shown
    controller.tickMinimizer(at: at(1), busy: true) // she's still talking about it
    controller.tickMinimizer(at: at(8), busy: true)
    controller.tickMinimizer(at: at(9), busy: false)
    controller.tickMinimizer(at: at(12.5), busy: false)
    let lingered = controller.phone.expanded
    controller.tickMinimizer(at: at(13.2), busy: false)
    check("what she shows rises, then goes back into the orb about 4 s after she's quiet",
          shown && lingered && !controller.phone.expanded && controller.phoneReason == nil, "")

    show("home")
    controller.phoneTouched()
    controller.tickMinimizer(at: at(30), busy: false)
    let kept = controller.phone.expanded
    controller.otherAppFocused()
    check("a result you touched stays; another app taking focus puts it away", kept && !controller.phone.expanded, "")

    show("home")
    controller.activation(.dismiss, at: at(31))
    check("the conversation's end puts away what she showed", !controller.phone.expanded && controller.conversation.isIdle,
          "\(controller.conversation)")

    let ask = registry.call("set_model", arguments: json(["provider": "openai"]), userInitiated: true).output
    controller.sessionSaid(.toolResult(name: "set_model", output: ask))
    let asked = controller.phone.expanded && controller.phone.screen == .messages && controller.phoneReason == .question
    controller.tickMinimizer(at: at(40), busy: false)
    controller.otherAppFocused()
    controller.hideConversation()
    let held = controller.phone.expanded
    gate.heard("no")
    controller.tickMinimizer(at: at(60), busy: false)
    controller.tickMinimizer(at: at(64.5), busy: false)
    check("her question opens the conversation and holds the phone up until it's answered",
          asked && held && !controller.phone.expanded, ask.prefix(40).description)

    controller.openPhone(.home, activate: false)
    controller.gestureBarTapped()
    let barred = !controller.phone.expanded
    controller.openPhone(.home, activate: false)
    controller.escapeInPhone()
    check("the gesture bar and Esc put the phone back into the orb", barred && !controller.phone.expanded, "")
    controller.activation(.reset)
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
