import Foundation

/// What the companion harness asks of the app it runs in: the session and the phone, which only the app has, and the
/// registry its settings live in. The app implements it; tests fake it.
public protocol CompanionApp: AnyObject, Sendable {
    /// Does one session or screen action and says what came of it in a few words. Called off the main thread.
    func perform(_ action: CompanionHarness.AppAction) -> String
    /// The voice model in use, whose voices `set_voice` accepts.
    var provider: Provider { get }
    /// The voice models the app offers.
    var providers: [Provider] { get }
    /// Where the settings are changed, as the human's own edits.
    var registry: SkillRegistry? { get }
}

/// Her own app, controlled by voice with native tool calls: the session (mute, pause, disconnect, stop speaking),
/// the phone (show a screen, back to the orb) and every setting. The human never has to click or type.
///
/// These are the human's own edits made by voice, never proposals: they go through the registry's human-edit path,
/// logged as the user's ("… (by voice)"), and the governance that keeps human-owned paths out of `propose_change`
/// stays as it is. Two tiers decide when a spoken yes is needed (through `ConfirmGate`, so only the user's own words
/// confirm): what raises her power or changes the bill (the voice model, switching on a harness, AppleScript or the
/// shell, a reset) always asks; everything else applies at once when the user asked for it, and asks when the call
/// comes from anything else (an agent report, a tool's output).
public struct CompanionHarness: Harness {
    /// What only the app can do.
    public enum AppAction: Equatable, Sendable {
        case mute(Bool), pause, resume, disconnect, stopSpeaking
        /// A phone screen by name (`PhoneScreen.named` in the app): home, messages, settings, skills, shade, lock.
        case show(String)
        case collapse
    }

    /// What one call changes.
    public enum Change: Equatable, Sendable {
        case app(AppAction)
        case activation(ActivationMode)
        case followUp(Double)
        case wakePhrase(String)
        case voice(String)
        case routing(jev: Bool?, model: String?)
        case model(Provider)
        /// A harness entry by id (`harness.mac`), on or off.
        case harness(String, on: Bool)
        case appleScript(Bool)
        case shell(Bool)
        case resetToNewHire
    }

    public static let screens = ["home", "chat", "messages", "conversations", "settings", "skills", "shade", "lock"]
    static let followUpRange: ClosedRange<Double> = 3...60

    private let app: (any CompanionApp)?
    private let gate: ConfirmGate

    /// Without an app (the plugin, a bare registry) it exists but isn't available.
    public init(app: (any CompanionApp)?, gate: ConfirmGate = .shared) {
        self.app = app
        self.gate = gate
    }

    public var id: String { "companion" }
    public var title: String { "Voice Companion" }
    public var summary: String {
        "Her own app: mute or pause the session, disconnect, stop speaking; show the phone's screens or put it away; "
            + "how she listens (tap to talk, wake word, always on), the follow-up time and wake phrase, her voice, "
            + "routing, the voice model, harnesses, AppleScript, the shell, and a reset."
    }
    public var isAvailable: Bool { app != nil }
    public var actions: ToolList { ToolList(Self.schemas) }

    // MARK: tiers

    /// Raises her power or changes the bill: always the user's spoken yes.
    public static func raisesPower(_ change: Change) -> Bool {
        switch change {
        case .model, .resetToNewHire: true
        case .harness(_, let on), .appleScript(let on), .shell(let on): on
        default: false
        }
    }

    /// Whether this call needs a spoken yes: always for what raises her power; otherwise only when the user didn't
    /// just ask (the model acting on a report or a tool's output).
    public static func needsYes(_ change: Change, userInitiated: Bool) -> Bool {
        raisesPower(change) || !userInitiated
    }

    // MARK: calls

    public func call(_ name: String, arguments: String, userInitiated: Bool) -> HerdrTools.Outcome {
        HerdrTools.Outcome(output: run(name, arguments: arguments, userInitiated: userInitiated), watch: nil)
    }

    func run(_ name: String, arguments: String, userInitiated: Bool) -> String {
        guard let app else { return "error: her app isn't running" }
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        let change: Change
        do {
            change = try Self.change(name, args, provider: app.provider, providers: app.providers)
        } catch {
            return "error: \(error). Nothing changed."
        }
        let confirmed = args["confirmed"] as? Bool ?? false
        let key = "\(name):\(Self.canonical(args))"
        // A yes asked for earlier is spent here even if the user has since spoken, so it doesn't linger.
        if Self.needsYes(change, userInitiated: userInitiated) || (confirmed && gate.pendingAction == key),
           let stop = HerdrTools.confirmStep(name, action: key, question: Self.question(change), confirmed: confirmed, gate) {
            return stop
        }
        return apply(change, app: app)
    }

    private func apply(_ change: Change, app: any CompanionApp) -> String {
        if case .app(let action) = change { return app.perform(action) }
        guard let registry = app.registry else { return "error: her settings aren't loaded. Nothing changed." }
        do {
            return try Self.edit(change, registry)
        } catch {
            return "error: \(error). Nothing changed."
        }
    }

    /// Applies a settings change as the user's own edit, logged as made by voice. Returns what changed, in words.
    static func edit(_ change: Change, _ registry: SkillRegistry) throws -> String {
        func set(_ summary: String, _ key: String, _ value: JSONValue) throws -> String {
            try registry.applyUserEdit(summary + " (by voice)") { tree in
                guard var settings = tree["settings"] else { throw ComponentError("there is no settings entry") }
                settings.config[key] = value
                tree["settings"] = settings
            }
            return "Done: " + summary.prefix(1).lowercased() + summary.dropFirst() + "."
        }
        switch change {
        case .app:
            throw ComponentError("not a setting")
        case .activation(let mode):
            return try set("Listening set to \(mode.title.lowercased())", "activation", .string(mode.rawValue))
        case .followUp(let seconds):
            return try set("Follow-up window set to \(Int(seconds)) seconds", "followUpSeconds", .number(seconds))
        case .wakePhrase(let phrase):
            return try set("Wake phrase set to \(phrase)", "wakePhrase", .string(phrase))
        case .voice(let name):
            return try set("Voice set to \(name)", "voice", .string(name))
        case .routing(let jev, let model):
            var said: [String] = []
            try registry.applyUserEdit("Routing changed (by voice)") { tree in
                guard var settings = tree["settings"] else { throw ComponentError("there is no settings entry") }
                if let jev { settings.config["routeWithJev"] = .bool(jev) }
                if let model { settings.config["jevModel"] = .string(model) }
                tree["settings"] = settings
            }
            if let jev { said.append(jev ? "routing with Jev" : "routing by words") }
            if let model { said.append("Jev model \(model)") }
            return "Done: " + said.joined(separator: ", ") + "."
        case .model(let provider):
            try registry.applyUserEdit("Switched the voice model to \(provider.menuTitle) (by voice)") { tree in
                guard var settings = tree["settings"] else { throw ComponentError("there is no settings entry") }
                settings.config["provider"] = .string(provider.rawValue)
                // Voice names differ per provider: back to the new one's default, as the app's picker does.
                if settings.config["voice"]?.string != nil { settings.config["voice"] = .null }
                tree["settings"] = settings
            }
            return "Done: switching to \(provider.menuTitle)."
        case .harness(let id, let on):
            try switchEntry(id, on: on, registry)
            return "Done: \(registry.tree[id]?.config["harness"]?.string ?? id) is \(on ? "on" : "off")."
        case .shell(let on):
            try switchEntry("harness.shell", on: on, registry)
            return "Done: the shell is \(on ? "on; each command still needs your yes" : "off")."
        case .appleScript(let on):
            try registry.applyUserEdit("\(on ? "Allowed" : "Stopped") AppleScript (by voice)") { tree in
                guard var mac = tree["harness.mac"] else { throw ComponentError("there is no Mac harness") }
                mac.config["appleScript"] = .bool(on)
                tree["harness.mac"] = mac
            }
            return "Done: AppleScript is \(on ? "on; each script still needs your yes" : "off")."
        case .resetToNewHire:
            try registry.applyUserEdit("Reset to a new hire (by voice)") { $0 = $0.resetToNewHire() }
            return "Done: I'm a new hire again. You can undo it from How I've changed."
        }
    }

    private static func switchEntry(_ id: String, on: Bool, _ registry: SkillRegistry) throws {
        try registry.applyUserEdit("\(on ? "Switched on" : "Switched off") \(id) (by voice)") { tree in
            guard var entry = tree[id] else { throw ComponentError("there is no \(id)") }
            entry.disabled = !on
            tree[id] = entry
        }
    }

    // MARK: arguments

    /// Reads a call into what it changes, or says what's wrong with it.
    static func change(_ name: String, _ args: [String: Any], provider: Provider, providers: [Provider]) throws -> Change {
        func text(_ key: String) -> String? {
            (args[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func flag(_ key: String) throws -> Bool {
            guard let value = args[key] as? Bool else { throw ComponentError("say \(key) as true or false") }
            return value
        }
        switch name {
        case "mute_mic": return .app(.mute(try flag("on")))
        case "pause_session": return .app(.pause)
        case "resume_session": return .app(.resume)
        case "disconnect_session": return .app(.disconnect)
        case "stop_speaking": return .app(.stopSpeaking)
        case "show_screen":
            guard let screen = text("screen")?.lowercased(), screens.contains(screen) else {
                throw ComponentError("show one of: " + screens.joined(separator: ", "))
            }
            return .app(.show(screen))
        case "collapse_phone": return .app(.collapse)
        case "set_activation":
            guard let mode = text("mode").flatMap(activationMode) else {
                throw ComponentError("the mode is tapToTalk, wakeWord or alwaysOn")
            }
            return .activation(mode)
        case "set_follow_up":
            guard let seconds = (args["seconds"] as? NSNumber)?.doubleValue else { throw ComponentError("say how many seconds") }
            guard followUpRange.contains(seconds.rounded()) else {
                throw ComponentError("the follow-up window is \(Int(followUpRange.lowerBound)) to "
                                     + "\(Int(followUpRange.upperBound)) seconds")
            }
            return .followUp(seconds.rounded())
        case "set_wake_phrase":
            guard let phrase = text("phrase"), phrase.count <= 40, WakePhrase.normalize(phrase).split(separator: " ").count >= 2
            else { throw ComponentError("the wake phrase is two to a few words, like Hey Companion") }
            return .wakePhrase(phrase)
        case "set_voice":
            guard let wanted = text("name") else { throw ComponentError("say which voice") }
            guard let voice = provider.voices.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw ComponentError("\(provider.menuTitle) has no voice called \(wanted); its voices are "
                                     + provider.voices.joined(separator: ", "))
            }
            return .voice(voice)
        case "set_routing":
            let jev = args["jev"] as? Bool, model = text("model")
            guard jev != nil || model != nil else { throw ComponentError("say whether to route with Jev, or which model") }
            return .routing(jev: jev, model: model)
        case "set_model":
            guard let wanted = text("provider")?.lowercased(),
                  let next = providers.first(where: { $0.rawValue == wanted || $0.menuTitle.lowercased() == wanted
                                                      || (wanted == "openai" && $0 == .openai) }) else {
                throw ComponentError("the voice model is one of " + providers.map(\.rawValue).joined(separator: ", "))
            }
            return .model(next)
        case "set_harness":
            guard let raw = text("harness")?.lowercased() else { throw ComponentError("say which harness") }
            return .harness(raw.hasPrefix("harness.") ? raw : "harness." + raw, on: try flag("on"))
        case "set_applescript": return .appleScript(try flag("on"))
        case "set_shell": return .shell(try flag("on"))
        case "reset_to_new_hire": return .resetToNewHire
        default: throw ComponentError("there is no app control called \(name)")
        }
    }

    static func activationMode(_ text: String) -> ActivationMode? {
        if let mode = ActivationMode(rawValue: text) { return mode }
        let words = text.lowercased()
        if words.contains("wake") { return .wakeWord }
        if words.contains("always") { return .alwaysOn }
        if words.contains("tap") || words.contains("push") || words.contains("key") { return .tapToTalk }
        return nil
    }

    /// The question asked before a change that needs a yes.
    static func question(_ change: Change) -> String {
        switch change {
        case .app(.mute(let on)): on ? "may I mute your mic" : "may I unmute your mic"
        case .app(.pause): "may I pause"
        case .app(.resume): "may I resume"
        case .app(.disconnect): "may I disconnect"
        case .app(.stopSpeaking): "may I stop speaking"
        case .app(.show(let screen)): "may I show \(screen)"
        case .app(.collapse): "may I put the phone away"
        case .activation(let mode): "may I set listening to \(mode.title.lowercased())"
        case .followUp(let seconds): "may I set the follow-up window to \(Int(seconds)) seconds"
        case .wakePhrase(let phrase): "may I set the wake phrase to \(phrase)"
        case .voice(let name): "may I switch my voice to \(name)"
        case .routing: "may I change how turns are routed"
        case .model(let provider): "may I switch my voice model to \(provider.menuTitle)"
        case .harness(let id, let on): "may I switch \(on ? "on" : "off") \(id.replacingOccurrences(of: "harness.", with: ""))"
        case .appleScript(let on): on ? "may I allow AppleScript" : "may I stop AppleScript"
        case .shell(let on): on ? "may I switch on the shell" : "may I switch off the shell"
        case .resetToNewHire: "may I reset myself to a new hire, forgetting every skill and fact"
        }
    }

    private static func canonical(_ args: [String: Any]) -> String {
        var args = args
        args["confirmed"] = nil
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: schemas

    static let askAgain = "If it answers CONFIRMATION REQUIRED, ask the user and call again with confirmed=true after "
        + "they say yes."

    static var schemas: [[String: Any]] {
        let on: [String: Any] = ["type": "boolean", "description": "true for on, false for off"]
        let confirmed = HerdrTools.confirmedField
        return [
            HerdrTools.fn("mute_mic", "Mute or unmute the user's microphone for this conversation (she can still talk). "
                          + askAgain, ["on": on, "confirmed": confirmed], ["on"]),
            HerdrTools.fn("pause_session", "Pause: mic off, speech stopped, replies and agent reports held until resume.",
                          ["confirmed": confirmed], []),
            HerdrTools.fn("resume_session", "End a pause.", ["confirmed": confirmed], []),
            HerdrTools.fn("disconnect_session", "Close the voice session now, so billing stops; it stays closed until the "
                          + "user connects, taps or types.", ["confirmed": confirmed], []),
            HerdrTools.fn("stop_speaking", "Stop what she is saying.", ["confirmed": confirmed], []),
            HerdrTools.fn("show_screen", "Open the phone on a screen: home (the cockpit), chat (this conversation as "
                          + "voice notes), conversations (the kept ones), settings, skills, shade (the drawer: apps, "
                          + "quick settings and notifications) or lock. A tap only lights the orb; open the phone only when "
                          + "there is something to see (a list, a link, a result), and it goes away by itself a few "
                          + "seconds after you finish talking about it.",
                          ["screen": ["type": "string", "enum": screens], "confirmed": confirmed], ["screen"]),
            HerdrTools.fn("collapse_phone", "Put the phone away, back to the orb.", ["confirmed": confirmed], []),
            HerdrTools.fn("set_activation", "How she listens: tapToTalk (tap the key, the default and cheapest), wakeWord "
                          + "(the wake phrase) or alwaysOn (always listening, the most expensive). " + askAgain,
                          ["mode": ["type": "string", "enum": ActivationMode.allCases.map(\.rawValue)], "confirmed": confirmed],
                          ["mode"]),
            HerdrTools.fn("set_follow_up", "After her reply, how many seconds the user can keep talking without the key "
                          + "(3 to 60). " + askAgain,
                          ["seconds": ["type": "number", "description": "3 to 60"], "confirmed": confirmed], ["seconds"]),
            HerdrTools.fn("set_wake_phrase", "The phrase that starts a conversation in wake word mode. " + askAgain,
                          ["phrase": HerdrTools.str("Two to a few words, like Hey Companion"), "confirmed": confirmed],
                          ["phrase"]),
            HerdrTools.fn("set_voice", "Her voice, one of the current voice model's voices. " + askAgain,
                          ["name": HerdrTools.str("The voice's name, e.g. eve, rex, marin or Kore"), "confirmed": confirmed],
                          ["name"]),
            HerdrTools.fn("set_routing", "Whether each turn is routed to a skill with Jev (or by matching words), and "
                          + "Jev's model. " + askAgain,
                          ["jev": on, "model": HerdrTools.str("Jev's model, e.g. jev-1.14.0"), "confirmed": confirmed], []),
            HerdrTools.fn("set_model", "Switch the voice model she runs on (grok, openai or gemini). It changes the bill, "
                          + "so it always needs the user's spoken yes: call without confirmed first.",
                          ["provider": ["type": "string", "enum": ["grok", "openai", "gemini"]], "confirmed": confirmed],
                          ["provider"]),
            HerdrTools.fn("set_harness", "Switch one of her harnesses (mac, herdr, shell, companion) on or off. Switching "
                          + "one on always needs the user's spoken yes.",
                          ["harness": HerdrTools.str("mac, herdr, shell or companion"), "on": on, "confirmed": confirmed],
                          ["harness", "on"]),
            HerdrTools.fn("set_applescript", "Allow or stop AppleScript on the Mac. Allowing it always needs the user's "
                          + "spoken yes.", ["on": on, "confirmed": confirmed], ["on"]),
            HerdrTools.fn("set_shell", "Switch shell commands on or off. Switching on always needs the user's spoken yes.",
                          ["on": on, "confirmed": confirmed], ["on"]),
            HerdrTools.fn("reset_to_new_hire", "Reset her to a new hire: every skill, fact and learned instruction is "
                          + "forgotten (it can be undone). Always needs the user's spoken yes.", ["confirmed": confirmed], []),
        ]
    }
}

public extension HarnessFactory {
    /// The standard harnesses, with her own app's controls running in `app`.
    static func companion(_ app: any CompanionApp, gate: ConfirmGate = .shared) -> HarnessFactory {
        HarnessFactory { name, config in
            name == "companion" ? CompanionHarness(app: app, gate: gate) : try HarnessFactory.standard.make(name, config)
        }
    }
}

public extension Provider {
    /// The voices each model offers by name (Grok also takes cloned voice IDs, set in the app).
    var voices: [String] {
        switch self {
        case .grok: ["eve", "rex", "ara", "sal", "leo"]
        case .openai: ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
        case .gemini: ["Kore", "Puck", "Charon", "Aoede", "Fenrir", "Leda", "Orus", "Zephyr", "Callirrhoe", "Autonoe",
                       "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi",
                       "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird",
                       "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"]
        case .local: [defaultVoice]
        }
    }
}
