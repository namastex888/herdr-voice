import AppKit
import HerdrVoiceCore
import SwiftUI
import VoiceEngine

/// The phone's side of the controller: opening and closing it, what its screens list (apps, tiles), how a
/// conversation shows, and the frame clock that drives the orb, the light bar and the conversation.
extension CompanionController {
    static let frameInterval: TimeInterval = 1.0 / 30
    static let hintShownKey = "VoiceCompanion.talkHintShown"

    // MARK: opening and closing

    /// `activate`: the user asked (a click, the menu), so the phone takes focus. `reason` says why it's up, which
    /// decides when it goes away by itself (`AutoMinimize`): what the user opened stays until they put it away or
    /// move to another app; what she showed goes a few seconds after she's done with it.
    func openPhone(_ screen: PhoneScreen? = nil, activate: Bool, reason: AutoMinimize.Reason = .user) {
        if let screen, phone.expanded { phone.go(screen) }
        phoneWindow?.expand(to: screen, activate: activate)
        _ = minimizer.handle(.opened(reason, at: Date()))
        syncPhoneReason()
    }

    func collapsePhone() {
        _ = minimizer.handle(.collapsed)
        syncPhoneReason()
        phoneWindow?.collapse()
    }

    func togglePhone() {
        if phone.expanded { collapsePhone() } else { openPhone(.home, activate: true) }
    }

    /// The gesture bar: the drawer up if it's down, otherwise back to the orb.
    func gestureBarTapped() {
        if phone.shadeOpen {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { phone.shadeOpen = false }
        } else {
            collapsePhone()
        }
    }

    /// A conversation started by a tap, the wake word or her own report: the orb lights up and listens; the phone
    /// stays put unless she has something to show (`show_screen`) or a question for you.
    func showConversation() {
        conversationStarted = Date()
    }

    /// The conversation ended: what she put up goes back into the orb, unless you've used it or she still waits
    /// for your yes.
    func hideConversation() {
        if minimizer.handle(.conversationEnded) { minimize() }
    }

    /// Esc while the phone has focus: the drawer up, or her speech or the conversation over and the phone back
    /// into the orb.
    func escapeInPhone() {
        if phone.shadeOpen {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { phone.shadeOpen = false }
            return
        }
        if !conversation.isIdle || chat.controls.speaking { escape() }
        collapsePhone()
    }

    /// The sheet's close button and its scrim.
    func dismissConversation() {
        if activationMode.opensOnRequest { activation(.dismiss) } else { stopSpeaking() }
    }

    /// The assistant sheet rises over what you opened yourself; over what she showed (a result, her question) it
    /// would hide the very thing she put up, and the orb already shows she listens.
    var showsAssistant: Bool {
        guard phoneReason == .user, phone.screen != .messages else { return false }
        return !conversation.isIdle || (activationMode == .alwaysOn && chat.controls.speaking && phone.expanded)
    }

    // MARK: what the screens list

    var homeApps: [PhoneApp] {
        var apps = harnesses.map { harness in
            PhoneApp(id: harness.id, kind: .harness, title: harness.title, symbol: Self.symbol(harness: harness.name),
                     dimmed: harness.status != .active)
        }
        apps += skills.map {
            PhoneApp(id: $0.id, kind: .skill, title: $0.skill.title, symbol: "sparkles", dimmed: $0.status != .active)
        }
        let slots = max(1, 4 - skills.count)
        apps += (0..<slots).map { PhoneApp(id: "teach.\($0)", kind: .teach, title: "Teach me", symbol: "plus") }
        return Array(apps.prefix(12))
    }

    var dockApps: [PhoneApp] {
        [PhoneApp(id: "messages", kind: .messages, title: "Messages", symbol: "bubble.left.and.text.bubble.right.fill"),
         PhoneApp(id: "talk", kind: .talk, title: "Talk", symbol: "mic.fill"),
         PhoneApp(id: "skills", kind: .skills, title: "Skills", symbol: "square.grid.2x2.fill"),
         PhoneApp(id: "settings", kind: .settings, title: "Settings", symbol: "gearshape.fill")]
    }

    static func symbol(harness name: String) -> String {
        switch name {
        case "mac": "laptopcomputer"
        case "herdr": "rectangle.split.3x1.fill"
        case "shell": "apple.terminal.fill"
        case "companion": "iphone.gen3"
        default: "puzzlepiece.extension.fill"
        }
    }

    func openApp(_ app: PhoneApp) {
        switch app.kind {
        case .harness, .skill: phone.go(.app(app.id))
        case .teach:
            phone.go(.messages)
            chat.note("Teach her out loud or here: “when I say start my day, open Mail and Calendar and set the volume to 30”.")
        case .messages: phone.go(.messages)
        case .skills: phone.go(.skills)
        case .settings: phone.go(.settings)
        case .talk: talkTapped()
        }
    }

    var quickTiles: [QuickTileModel] {
        let c = chat.controls, mode = activationMode
        return [
            QuickTileModel(id: "mic", title: "Mic", subtitle: c.muted ? "Off" : "On", symbol: c.muteSymbol,
                           on: !c.muted, enabled: c.available) { [weak self] in self?.press(c.mutePress) },
            QuickTileModel(id: "pause", title: c.paused ? "Paused" : "Pause", subtitle: c.paused ? "Tap to resume" : "Hold all",
                           symbol: c.pauseSymbol, on: c.paused, enabled: c.available) { [weak self] in self?.press(c.pausePress) },
            QuickTileModel(id: "session", title: "Session", subtitle: c.state, symbol: c.connectSymbol,
                           on: c.link == .connected, enabled: c.available) { [weak self] in self?.press(c.connectPress) },
            QuickTileModel(id: "activation", title: "Listen", subtitle: mode.title,
                           symbol: Self.symbol(mode), on: mode != .alwaysOn, enabled: true) { [weak self] in
                self?.cycleActivation()
            },
            QuickTileModel(id: "stop", title: "Stop", subtitle: c.speaking ? "Speaking" : "Quiet",
                           symbol: SessionControls.stopSymbol, on: false, enabled: c.canStopSpeaking) { [weak self] in
                self?.stopSpeaking()
            },
            QuickTileModel(id: "talk", title: "Talk", subtitle: talkKey, symbol: "waveform", on: !conversation.isIdle,
                           enabled: c.available) { [weak self] in self?.talkTapped() },
        ]
    }

    static func symbol(_ mode: ActivationMode) -> String {
        switch mode {
        case .tapToTalk: "hand.tap.fill"
        case .wakeWord: "waveform.badge.mic"
        case .alwaysOn: "ear.fill"
        }
    }

    func cycleActivation() {
        let all = ActivationMode.allCases
        setActivation(all[((all.firstIndex(of: activationMode) ?? 0) + 1) % all.count])
    }

    // MARK: words for the state

    /// How to start talking, in the current mode.
    var talkHint: String {
        switch activationMode {
        case .tapToTalk: keyMonitor?.running == true ? "Tap \(settings.activationKey.title) to talk" : "Press \(Hotkey.label) to talk"
        case .wakeWord: "Say “\(settings.wakePhrase)”"
        case .alwaysOn: "Just talk"
        }
    }

    /// The talk trigger in a word or two, for a tile.
    var talkKey: String {
        switch activationMode {
        case .tapToTalk: keyMonitor?.running == true ? settings.activationKey.title : Hotkey.label
        case .wakeWord: "Wake word"
        case .alwaysOn: "Always on"
        }
    }

    var talkSymbol: String {
        switch activationMode {
        case .tapToTalk: keyMonitor?.running == true ? "command" : "keyboard"
        case .wakeWord: "waveform"
        case .alwaysOn: "ear"
        }
    }

    var stateSymbol: String {
        let c = chat.controls
        if c.link == .disconnected || !c.available { return "phone.down.fill" }
        if c.paused { return "pause.fill" }
        if c.muted { return "mic.slash.fill" }
        return c.link == .connected ? "dot.radiowaves.left.and.right" : "moon.zzz.fill"
    }

    var orbHelp: String { "\(name) · \(chat.controls.state) · \(talkHint). Click for the phone; right-click for controls." }

    /// What the sheet says before she does.
    var conversationPrompt: String {
        switch conversation {
        case .idle, .listening(heard: false, _): chat.controls.muted ? "Your mic is off." : "Hi, I'm listening…"
        case .listening: "…"
        case .cooldown: "Go on, or I'll answer…"
        case .replying: "Thinking…"
        case .followUp: "Anything else?"
        }
    }

    /// The sheet's chip.
    var conversationStatus: String {
        if chat.controls.muted { return "Muted" }
        if handsFree, case .listening = conversation { return "Hands-free" }
        switch conversation {
        case .idle: return chat.controls.speaking ? "Speaking" : "Idle"
        case .listening: return "Listening"
        case .cooldown: return "Sending…"
        case .replying: return chat.controls.speaking ? "Speaking" : "Thinking"
        case .followUp(_, let until): return "Follow-up \(max(0, Int(until.timeIntervalSinceNow.rounded(.up)))) s"
        }
    }

    // MARK: the look

    var accent: PhoneTheme.Seed {
        tree["settings"]?.config["accent"]?.string.flatMap(PhoneTheme.Seed.init(rawValue:)) ?? .default
    }

    func setAccent(_ seed: PhoneTheme.Seed) {
        guard seed != accent else { return }
        edit { try registry.setField("settings", "accent", .string(seed.rawValue)) }
        followAccent()
    }

    /// The theme follows the tree (your pick, a revert).
    func followAccent() {
        let seed = accent
        if phone.theme.seed != seed { withAnimation(.easeInOut(duration: 0.4)) { phone.theme = PhoneTheme(seed: seed) } }
    }

    // MARK: frames

    func startFrames() {
        guard frameTimer == nil else { return }
        frameTimer = Timer.scheduledTimer(withTimeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frameTick() }
        }
    }

    /// Every frame: the controls catch up with the session, the conversation's clock ticks, and the orb and the light
    /// bar get their levels.
    func frameTick(at now: Date = Date()) {
        syncControls()
        runDeferredPress(at: now)
        tickActivation(at: now)
        tickMinimizer(at: now)
        updateLive(at: now)
    }

    func updateLive(at now: Date = Date()) {
        guard let session else {
            return live.update(look: .mood(.offline), mic: 0, voice: 0, thinking: false, listening: false, cooldown: nil,
                               followUp: nil)
        }
        let c = chat.controls, audio = session.audio
        // Between conversations nothing listens, so the orb rests rather than showing "listening".
        let resting = activationMode.opensOnRequest && conversation.isIdle && !c.speaking && c.available
            && c.link != .disconnected && !c.paused && !c.muted
        let mood = Activity.mood(controls: c, loading: false, agentsWorking: !session.busyAgents.isEmpty,
                                 micQuiet: audio.micLevel < 0.02)
        live.update(look: resting ? .resting : .mood(mood),
                    mic: c.listening && !session.standby ? audio.micLevel : 0,
                    voice: audio.isSpeaking ? audio.outLevel : 0,
                    thinking: session.status != .disconnected && session.thinking,
                    listening: Self.lightsListening(conversation) && !c.muted && !c.paused,
                    cooldown: turns.cooldownProgress(at: now), followUp: turns.followUpRemaining(at: now))
    }

    /// The orb's listening glow: from the tap until the follow-up window closes, except while she answers.
    static func lightsListening(_ phase: TurnTaking.Phase) -> Bool {
        switch phase {
        case .listening, .cooldown, .followUp: true
        case .idle, .replying: false
        }
    }

    /// On first run, a bubble beside the orb says how to talk.
    func showFirstRunHint() {
        guard !UserDefaults.standard.bool(forKey: Self.hintShownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.hintShownKey)
        phoneWindow?.showHint(talkHint)
    }
}
