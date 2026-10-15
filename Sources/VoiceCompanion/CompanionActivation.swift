import AppKit
import HerdrVoiceCore
import VoiceEngine

/// When she listens. Tap-to-talk and the wake word keep the session closed and the mic on standby between
/// conversations, so nothing is billed: a tap (or the wake phrase) opens one, the provider's speech detection (once
/// the mic's speech sensor agrees it's you) says when you stopped, a short cooldown lets you go on (where the provider
/// can hold the reply), and the reply is asked for. After it,
/// the follow-up window lets you talk without the key; when it runs out the session closes again. `TurnTaking`
/// decides all of it; this file feeds it events and the clock and does what it says.
extension CompanionController {
    /// After speech stops, how long to wait for more before asking for the reply (where the provider can hold one).
    static let cooldown: TimeInterval = 0.5

    var activationMode: ActivationMode { settings.activation }

    /// Follows the tree's activation settings: the session's standby and deferred replies, the key monitor, the
    /// wake word and the conversation's timing. Safe to call again whenever they change.
    func applyActivation() {
        let mode = activationMode, settings = settings
        let holdsReplies = (session?.provider ?? provider).capabilities.deferredReplies
        turns.timing.cooldown = holdsReplies ? Self.cooldown : 0 // Grok and Gemini answer when you stop
        turns.timing.followUp = settings.followUpSeconds
        session?.deferReplies = mode.opensOnRequest
        var notes: [String] = []

        if mode.opensOnRequest {
            // Between conversations nothing stays open: a session left from always-on (or opened by a provider
            // switch) closes now rather than at the quiet close, three minutes later.
            if turns.phase.isIdle, let session, !session.standby || session.status != .disconnected {
                session.rest("tap to talk", quietly: true)
            }
            startKeyMonitor(settings.activationKey, notes: &notes)
        } else {
            activation(.reset)
            session?.setStandby(false)
            keyMonitor?.stop()
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
                         + "Input Monitoring. Until then the mic button starts a conversation; \(Hotkey.label) only "
                         + "mutes.")
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
        case .buffer:
            session?.buffer()
        case .discard:
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

    /// The on-screen talk button: a tap.
    func talkTapped() {
        if activationMode.opensOnRequest {
            activation(.tap)
        } else {
            session?.listen()
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

    /// Esc is grabbed system-wide only while she is audibly speaking; the phone, when it has focus, gets Esc like
    /// any window (`escapeInPhone`). Every other app keeps its Esc the rest of the time (`EscapeKey`).
    func updateEscape() {
        let owner = EscapeKey.owner(speaking: session?.audio.isSpeaking ?? false,
                                    phoneIsKey: phoneWindow?.panel.isKeyWindow ?? false)
        Hotkey.setStopKey(active: owner == .global) { [weak self] in self?.escape() }
    }

    /// Opens Input Monitoring's prompt (or its page in System Settings, once macOS has asked).
    func requestKeyPermission() {
        if !ActivationKeyMonitor.requestPermission() { NSWorkspace.shared.open(ActivationKeyMonitor.settingsURL) }
        applyActivation()
    }
}
