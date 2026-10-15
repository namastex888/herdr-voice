import Foundation
import Testing
@testable import HerdrVoiceCore

/// Her app, faked: records what it was asked to do, and holds a real registry for the settings.
private final class FakeApp: CompanionApp, @unchecked Sendable {
    private let lock = NSLock()
    private var done: [CompanionHarness.AppAction] = []
    weak var registry: SkillRegistry?
    var provider: Provider { .grok }
    var providers: [Provider] { [.grok, .openai, .gemini] }

    var performed: [CompanionHarness.AppAction] { lock.withLock { done } }

    func perform(_ action: CompanionHarness.AppAction) -> String {
        lock.withLock { done.append(action) }
        return "Done."
    }
}

/// A registry whose companion harness runs in a fake app, with a gate that answers at once.
private struct AppRig {
    let app = FakeApp()
    let gate = ConfirmGate(minDelay: 0, wait: 0)
    let registry: SkillRegistry

    init() {
        registry = SkillRegistry(store: nil, factory: .companion(app, gate: gate), gate: gate)
        app.registry = registry
    }

    func run(_ name: String, _ arguments: [String: Any] = [:], user: Bool = true) -> String {
        registry.run(name, arguments, user: user)
    }

    var settings: [String: JSONValue] { registry.tree["settings"]?.config ?? [:] }
}

@Test func herAppIsAHarnessLikeTheOthersWithEveryControl() {
    let rig = AppRig()
    #expect(rig.registry.status(of: "harness.companion") == .active)
    let names = Set(rig.registry.activeTools.names)
    for name in ["mute_mic", "pause_session", "resume_session", "disconnect_session", "stop_speaking", "show_screen",
                 "collapse_phone", "set_activation", "set_follow_up", "set_wake_phrase", "set_voice", "set_routing",
                 "set_model", "set_harness", "set_applescript", "set_shell", "reset_to_new_hire"] {
        #expect(names.contains(name), "\(name)")
    }
    // No name is shared with another harness's tools (the Mac has its own mute).
    #expect(rig.registry.tools.names.count == Set(rig.registry.tools.names).count)
    #expect(rig.registry.instructions.contains("harness.companion") && rig.registry.instructions.contains("computer use"))
}

@Test func theTiers() {
    let powerful: [CompanionHarness.Change] = [
        .model(.openai), .harness("harness.shell", on: true), .appleScript(true), .shell(true), .resetToNewHire,
    ]
    let everyday: [CompanionHarness.Change] = [
        .app(.mute(true)), .app(.pause), .app(.disconnect), .app(.stopSpeaking), .app(.show("settings")), .app(.collapse),
        .activation(.wakeWord), .followUp(12), .wakePhrase("Hey Robin"), .voice("rex"), .routing(jev: false, model: nil),
        .harness("harness.herdr", on: false), .appleScript(false), .shell(false),
    ]
    for change in powerful {
        #expect(CompanionHarness.raisesPower(change), "\(change)")
        #expect(CompanionHarness.needsYes(change, userInitiated: true), "\(change)")
    }
    for change in everyday {
        #expect(!CompanionHarness.raisesPower(change), "\(change)")
        #expect(!CompanionHarness.needsYes(change, userInitiated: true), "\(change)")
        #expect(CompanionHarness.needsYes(change, userInitiated: false), "\(change)") // a report's idea: ask
    }
}

@Test func whatYouAskForAppliesAtOnceAsYourOwnEditByVoice() {
    let rig = AppRig()
    #expect(rig.run("set_activation", ["mode": "wakeWord"]).hasPrefix("Done"))
    #expect(rig.run("set_follow_up", ["seconds": 15]).hasPrefix("Done"))
    #expect(rig.run("set_wake_phrase", ["phrase": "Hey Robin"]).hasPrefix("Done"))
    #expect(rig.run("set_voice", ["name": "Rex"]).hasPrefix("Done"))
    #expect(rig.run("set_routing", ["jev": false, "model": "jev-2"]).hasPrefix("Done"))
    #expect(rig.run("set_harness", ["harness": "herdr", "on": false]).hasPrefix("Done"))
    let s = rig.settings
    #expect(s["activation"] == .string("wakeWord") && s["followUpSeconds"] == .number(15))
    #expect(s["wakePhrase"] == .string("Hey Robin") && s["voice"] == .string("rex"))
    #expect(s["routeWithJev"] == .bool(false) && s["jevModel"] == .string("jev-2"))
    #expect(rig.registry.tree["harness.herdr"]?.disabled == true)
    // Each is logged as yours, made by voice, and can be reverted like any edit.
    #expect(rig.registry.changes.count == 6)
    #expect(rig.registry.changes.allSatisfy { $0.by == .user && $0.summary.hasSuffix("(by voice)") })
}

@Test func theSessionAndScreenActionsReachTheApp() {
    let rig = AppRig()
    _ = rig.run("mute_mic", ["on": true])
    _ = rig.run("pause_session")
    _ = rig.run("resume_session")
    _ = rig.run("stop_speaking")
    _ = rig.run("show_screen", ["screen": "settings"])
    _ = rig.run("collapse_phone")
    _ = rig.run("disconnect_session")
    #expect(rig.app.performed == [.mute(true), .pause, .resume, .stopSpeaking, .show("settings"), .collapse, .disconnect])
    #expect(rig.run("show_screen", ["screen": "camera"]).hasPrefix("error"))
    #expect(rig.run("mute_mic").hasPrefix("error")) // on or off has to be said
    #expect(rig.app.performed.count == 7)
}

@Test func aCallPromptedByAReportNeedsAYes() {
    let rig = AppRig()
    let asked = rig.run("set_activation", ["mode": "alwaysOn"], user: false)
    #expect(asked.hasPrefix("CONFIRMATION REQUIRED") && rig.settings["activation"] == nil)
    rig.gate.heard("no")
    #expect(rig.run("set_activation", ["mode": "alwaysOn", "confirmed": true], user: false).hasPrefix("NOT DONE"))
    #expect(rig.settings["activation"] == nil)
    #expect(rig.run("disconnect_session", user: false).hasPrefix("CONFIRMATION REQUIRED"))
    rig.gate.heard("no")
    #expect(rig.app.performed.isEmpty)

    _ = rig.run("set_activation", ["mode": "alwaysOn"], user: false)
    rig.gate.heard("yes")
    #expect(rig.run("set_activation", ["mode": "alwaysOn", "confirmed": true], user: false).hasPrefix("Done"))
    #expect(rig.settings["activation"] == .string("alwaysOn"))
}

@Test func whatRaisesHerPowerAlwaysNeedsASpokenYes() {
    let rig = AppRig()
    let before = rig.registry.tree
    let calls: [(String, [String: Any])] = [
        ("set_model", ["provider": "openai"]), ("set_harness", ["harness": "shell", "on": true]),
        ("set_applescript", ["on": true]), ("set_shell", ["on": true]), ("reset_to_new_hire", [:]),
    ]
    for (name, arguments) in calls {
        let asked = rig.run(name, arguments, user: true) // even though the user asked
        rig.gate.heard("no, leave it")
        var confirmed = arguments
        confirmed["confirmed"] = true
        let refused = rig.run(name, confirmed, user: true)
        #expect(asked.hasPrefix("CONFIRMATION REQUIRED") && refused.hasPrefix("NOT DONE"), "\(name): \(asked) / \(refused)")
    }
    #expect(rig.registry.tree == before && rig.registry.changes.isEmpty)

    // With the user's yes they apply.
    _ = rig.run("set_model", ["provider": "openai"])
    rig.gate.heard("yes, switch")
    #expect(rig.run("set_model", ["provider": "openai", "confirmed": true]).hasPrefix("Done"))
    #expect(rig.settings["provider"] == .string("openai"))
    _ = rig.run("set_applescript", ["on": true])
    rig.gate.heard("yes")
    #expect(rig.run("set_applescript", ["on": true, "confirmed": true]).hasPrefix("Done"))
    #expect(rig.registry.tree["harness.mac"]?.config["appleScript"] == .bool(true))
    // Turning it back off needs nothing.
    #expect(rig.run("set_applescript", ["on": false]).hasPrefix("Done"))
    #expect(rig.registry.tree["harness.mac"]?.config["appleScript"] == .bool(false))
}

@Test func aVoiceMustBeOneTheModelHas() {
    let rig = AppRig()
    #expect(rig.run("set_voice", ["name": "marin"]).contains("Grok has no voice called marin"))
    #expect(rig.run("set_follow_up", ["seconds": 600]).hasPrefix("error"))
    #expect(rig.run("set_wake_phrase", ["phrase": "Hey"]).hasPrefix("error"))
    #expect(rig.run("set_model", ["provider": "local"]).hasPrefix("error"))
    #expect(rig.registry.changes.isEmpty)
}

@Test func herAppsSettingsStillCantBeProposed() throws {
    let rig = AppRig()
    for path in ["settings.activation", "settings.provider", "harness.companion.disabled"] {
        let out = rig.run("propose_change", ["summary": "s", "changes": [["op": "set", "path": path, "value": "x"]]])
        #expect(out.contains("the human's to change"), "\(path): \(out)")
    }
}

@Test func anOlderTreeGetsHerAppsHarness() {
    var old = ConfigTree.factory
    old["harness.companion"] = nil
    let upgraded = old.addingMissingHarnesses()
    #expect(upgraded["harness.companion"] == ConfigTree.factory["harness.companion"])
    #expect(upgraded.harnessEntries.map(\.id) == ConfigTree.factory.harnessEntries.map(\.id))
    #expect(ConfigTree.factory.addingMissingHarnesses() == .factory)
}
