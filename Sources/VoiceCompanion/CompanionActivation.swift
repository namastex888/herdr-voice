import AppKit
import HerdrVoiceCore
import VoiceEngine

/// When she listens. Tap-to-talk and the wake word keep the session closed and the mic on standby between
/// conversations, so nothing is billed: a tap (or the wake phrase) opens one, the provider's speech detection (or
/// the session's gate) says when you stopped, a short cooldown lets you go on, and the reply is asked for. After it,
/// the follow-up window lets you talk without the key; when it runs out the session closes again. `TurnTaking`
/// decides all of it; this file feeds it events and the clock and does what it says.
extension CompanionController {
    /// After speech stops, how long to wait for more before asking for the reply (where the provider can hold one).
    static let cooldown: TimeInterval = 0.5
    /// How often the conversation's clock ticks (cooldown, follow-up, timeouts).
    static let activationTick: TimeInterval = 0.05

    var activationMode: ActivationMode { settings.activation }

    /// Follows the tree's activation settings: the session's standby and deferred replies, the key monitor, the
    /// wake word and the conversation's timing. Safe to call again whenever they change.
    func applyActivation() {
        let mode = activationMode, settings = settings
        let holdsReplies = (session?.provider ?? provider).capabilities.deferredReplies
        turns.timing.cooldown = holdsReplies ? Self.cooldown : 0 // Gemini answers when you stop; nothing to hold
        turns.timing.followUp = settings.followUpSeconds
        session?.deferReplies = mode.opensOnRequest
        var notes: [String] = []

        if mode.opensOnRequest {
            if turns.phase.isIdle { session?.setStandby(true) }
            startKeyMonitor(settings.activationKey, notes: &notes)
            startActivationClock()
        } else {
            activation(.reset)
            session?.setStandby(false)
            keyMonitor?.stop()
            activationTimer?.invalidate()
            activationTimer = nil
        }

        if mode == .wakeWord {
            startWakeWord(settings.wakePhrase)
        } else {
            wakeWord?.stop()
            wakeWord = nil
        }
        activationNote = notes.joined(separator: " ")
        updateEscape()
    }

    private func startKeyMonitor(_ key: ActivationKey, notes: inout [String]) {
        if keyMonitor == nil {
            keyMonitor = ActivationKeyMonitor(key: key) { [weak self] event in
                switch event {
                case .keyDown: self?.activation(.keyDown)
                case .keyUp: self?.activation(.keyUp)
                case .otherKey: self?.activation(.otherKey)
                }
            }
        }
        keyMonitor?.key = key
        if keyMonitor?.start() != true {
            notes.append("To use \(key.title), allow Voice Companion in System Settings → Privacy & Security → "
                         + "Input Monitoring. Until then \(Hotkey.label) or the talk button starts a conversation.")
        }
    }

    private func startWakeWord(_ phrase: String) {
        guard let session else { return }
        if let wakeWord {
            wakeWord.phrase = phrase
            return
        }
        let spotter = WakeWordSpotter(phrase: phrase) { [weak self] in self?.activation(.tap) }
        wakeWord = spotter
        spotter.start(audio: session.audio) { [weak self] status in
            guard let self, case .unavailable(let why) = status else { return }
            // Tap-to-talk still works: the key monitor runs in every on-request mode.
            self.activationNote = "The wake word can't listen: \(why). Tap \(self.settings.activationKey.title) to talk."
            self.chat.note(self.activationNote)
        }
    }

    private func startActivationClock() {
        guard activationTimer == nil else { return }
        activationTimer = Timer.scheduledTimer(withTimeInterval: Self.activationTick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickActivation() }
        }
    }

    func tickActivation(at now: Date = Date()) {
        guard activationMode.opensOnRequest else { return }
        activation(.assistant(busy: session?.replying ?? false), at: now)
        activation(.tick, at: now)
    }

    /// Feeds one event to the conversation and does what it says. Ignored in always-on mode, which has none.
    func activation(_ event: TurnTaking.Event, at now: Date = Date()) {
        guard activationMode.opensOnRequest || event == .reset else { return }
        let effects = turns.handle(event, at: now)
        for effect in effects { perform(effect) }
        if conversation != turns.phase { conversation = turns.phase }
        if handsFree != turns.handsFree { handsFree = turns.handsFree }
        if !effects.isEmpty {
            wakeWord?.setPaused(!turns.phase.isIdle)
            updateEscape()
            syncControls()
        }
    }

    private func perform(_ effect: TurnTaking.Effect) {
        switch effect {
        case .prewarm:
            session?.prewarm()
        case .cancelPrewarm:
            session?.rest("not a tap", quietly: true)
        case .open:
            session?.listen()
            showConversation()
        case .submit:
            session?.submitTurn()
        case .bargeIn:
            session?.stopSpeech(reason: "you tapped")
        case .close:
            session?.rest("conversation over")
            hideConversation()
        }
    }

    /// The on-screen talk button, and ⌥⌘M while the key can't be watched: a tap.
    func talkTapped() {
        if activationMode.opensOnRequest {
            activation(.tap)
        } else {
            session?.listen()
        }
    }

    /// ⌥⌘M: the talk tap where the activation key can't be watched; Mute otherwise.
    func hotkeyPressed() {
        if activationMode.opensOnRequest, keyMonitor?.running != true {
            talkTapped()
        } else {
            hotkeyMute()
        }
    }

    /// Esc ends a conversation in the on-request modes, and stops her speaking in always-on.
    func escape() {
        if activationMode.opensOnRequest, !turns.phase.isIdle {
            activation(.dismiss)
        } else {
            stopSpeaking()
        }
    }

    /// Esc is grabbed only while it means something here: she's speaking, or a conversation is on. Every other app
    /// keeps its Esc the rest of the time.
    func updateEscape() {
        let speaking = session?.audio.isSpeaking ?? false
        Hotkey.setStopKey(active: speaking || !turns.phase.isIdle) { [weak self] in self?.escape() }
    }

    /// Opens Input Monitoring's prompt (or its page in System Settings, once macOS has asked).
    func requestKeyPermission() {
        if !ActivationKeyMonitor.requestPermission() { NSWorkspace.shared.open(ActivationKeyMonitor.settingsURL) }
        applyActivation()
    }
}
