import Foundation

/// How the companion decides when to listen: the tree's `settings.activation`, the human's to set. Every mode but
/// `alwaysOn` keeps the session closed between conversations, so nothing is billed while nobody talks to her.
public enum ActivationMode: String, CaseIterable, Sendable {
    /// Tap the activation key and talk; she answers once you stop. The default.
    case tapToTalk
    /// Say the wake phrase instead of tapping the key, recognized on this Mac.
    case wakeWord
    /// The mic is always open and a session reopens whenever you speak (0.2's behaviour): the expensive one.
    case alwaysOn

    public static let `default` = ActivationMode.tapToTalk

    public var title: String {
        switch self {
        case .tapToTalk: "Tap to talk"
        case .wakeWord: "Wake word"
        case .alwaysOn: "Always on"
        }
    }

    public var detail: String {
        switch self {
        case .tapToTalk: "Tap the key, talk, and she answers when you stop. Nothing is billed between conversations."
        case .wakeWord: "Say the wake phrase instead of tapping. It's recognized on this Mac; nothing leaves it until then."
        case .alwaysOn: "Always listening: every sound can reopen a billed session. The expensive one."
        }
    }

    /// The session stays closed between conversations, and opens for one.
    public var opensOnRequest: Bool { self != .alwaysOn }
}

/// The modifier key that taps. A modifier alone does nothing anywhere else, so a tap of it is free to take; a chord
/// with it (⌘C) is someone else's shortcut and never activates.
public enum ActivationKey: String, CaseIterable, Sendable {
    case rightCommand, rightOption, rightControl, rightShift, function

    public static let `default` = ActivationKey.rightCommand

    public var title: String {
        switch self {
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        case .rightControl: "Right ⌃"
        case .rightShift: "Right ⇧"
        case .function: "fn"
        }
    }

    /// The virtual key code a `flagsChanged` event carries for this key (kVK_RightCommand and friends).
    public var keyCode: UInt16 {
        switch self {
        case .rightCommand: 0x36
        case .rightOption: 0x3D
        case .rightControl: 0x3E
        case .rightShift: 0x3C
        case .function: 0x3F
        }
    }

    /// The device-dependent flag bit that is set while this very key is down (NX_DEVICERCMDKEYMASK and friends; fn
    /// has only the shared one), so the left key held at the same time doesn't read as this one.
    public var deviceMask: UInt64 {
        switch self {
        case .rightCommand: 0x10
        case .rightOption: 0x40
        case .rightControl: 0x2000
        case .rightShift: 0x04
        case .function: 0x80_0000
        }
    }
}

/// Turns raw keyboard events into the activation key's own: down, up, and anything else pressed while it is down.
/// Pure, so the event tap stays a thin shell and this is tested with made-up events.
public struct ModifierTap: Sendable {
    public enum Event: Equatable, Sendable { case keyDown, keyUp, otherKey }

    /// The modifier flags every other modifier sets (shift, control, option, command, fn), to see a second one join.
    static let modifierMask: UInt64 = 0x02_0000 | 0x04_0000 | 0x08_0000 | 0x10_0000 | 0x80_0000

    public var key: ActivationKey
    public private(set) var down = false
    private var othersAtDown: UInt64 = 0

    public init(key: ActivationKey) { self.key = key }

    /// `flagsChanged`: a modifier went down or up. `keyCode` names which one; `flags` are the flags after it.
    public mutating func flagsChanged(keyCode: UInt16, flags: UInt64) -> Event? {
        let mine = flags & key.deviceMask != 0
        if keyCode == key.keyCode {
            if mine, !down {
                down = true
                othersAtDown = flags & Self.modifierMask & ~ownMask
                return .keyDown
            }
            if !mine, down {
                down = false
                return .keyUp
            }
            return nil
        }
        // Another modifier joined while ours is down: a chord in the making (⌘⇧4).
        guard down, flags & Self.modifierMask & ~ownMask != othersAtDown else { return nil }
        othersAtDown = flags & Self.modifierMask & ~ownMask
        return .otherKey
    }

    /// `keyDown` of any ordinary key: while ours is down, it makes a chord.
    public mutating func keyPressed() -> Event? { down ? .otherKey : nil }

    /// The shared flag our key sets, which another modifier must not be judged by.
    private var ownMask: UInt64 {
        switch key {
        case .rightCommand: 0x10_0000
        case .rightOption: 0x08_0000
        case .rightControl: 0x04_0000
        case .rightShift: 0x02_0000
        case .function: 0x80_0000
        }
    }
}

/// When the companion listens, submits a turn and lets go: pure logic the app drives with events and the clock
/// (the tests with made-up times). idle → listening → (speech stops) → cooldown → replying → follow-up → idle, with
/// cancel, barge-in and dismiss edges. The app does what each returned `Effect` says.
public struct TurnTaking: Sendable {
    public enum Phase: Equatable, Sendable {
        /// Nothing going on: the session is closed (or closing) and nothing is streamed.
        case idle
        /// Open and listening. `heard`: speech began in this turn.
        case listening(heard: Bool, since: Date)
        /// Speech stopped; the turn is submitted at `until`, unless speech resumes first.
        case cooldown(since: Date, until: Date)
        /// Submitted: waiting for her reply, or hearing it.
        case replying(since: Date)
        /// She finished; talk without the key until `until`.
        case followUp(since: Date, until: Date)

        public var isIdle: Bool { self == .idle }
    }

    public enum Event: Equatable, Sendable {
        /// The activation key, down and up alone, or another key pressed while it was down.
        case keyDown, keyUp, otherKey
        /// The wake phrase, the on-screen talk button or the fallback hotkey: a tap without a key to hold.
        case tap
        /// The session heard speech start or stop (the provider's VAD, or the local gate where turns are manual).
        case speechStarted, speechStopped
        /// She is thinking, running tools or speaking (busy), or none of it.
        case assistant(busy: Bool)
        /// Esc, or "that's all": the conversation is over.
        case dismiss
        /// The session was closed or reset from elsewhere (Disconnect, a provider switch): forget the turn quietly.
        case reset
        /// Time passed.
        case tick
    }

    public enum Effect: Equatable, Sendable {
        /// The key went down from idle: start keeping the mic's audio here, in case this is a tap. Nothing connects:
        /// a key-down may be the start of ⌘C, and a stray connect is billed.
        case buffer
        /// It was a chord after all (or held too long): back to standby, the kept audio dropped.
        case discard
        /// A real tap (or the wake word): connect, send what was kept, show the conversation and listen.
        case open
        /// Ask for the reply to what was heard.
        case submit
        /// Stop her speaking and listen.
        case bargeIn
        /// The conversation is over: stop, close the session softly so billing stops, and put the phone away.
        case close
    }

    public struct Timing: Equatable, Sendable {
        /// After speech stops, how long to wait for more before submitting. Zero where the provider answers by
        /// itself (Gemini): the turn is gone the moment speech stops.
        public var cooldown: TimeInterval
        /// After her reply, how long you can talk without the key.
        public var followUp: TimeInterval
        /// Tapped but said nothing: how long to wait before letting go.
        public var listenTimeout: TimeInterval
        /// Submitted but no reply at all: when to stop waiting for one.
        public var replyTimeout: TimeInterval
        /// A key held longer than this isn't a tap (a ⌘ held while deciding on a shortcut).
        public var tapMax: TimeInterval
        /// Two taps closer than this are a double tap.
        public var doubleTap: TimeInterval

        public init(cooldown: TimeInterval = 0.5, followUp: TimeInterval = 8, listenTimeout: TimeInterval = 10,
                    replyTimeout: TimeInterval = 20, tapMax: TimeInterval = 0.8, doubleTap: TimeInterval = 0.4) {
            self.cooldown = cooldown
            self.followUp = followUp
            self.listenTimeout = listenTimeout
            self.replyTimeout = replyTimeout
            self.tapMax = tapMax
            self.doubleTap = doubleTap
        }
    }

    public var timing: Timing
    public private(set) var phase: Phase = .idle
    /// Double-tapped: the conversation goes on (no follow-up countdown) until Esc, "that's all" or another double tap.
    public private(set) var handsFree = false
    private var keyDownAt: Date?
    private var chord = false
    /// Mic audio is being kept for a key press that hasn't resolved yet.
    private var buffering = false
    private var lastTap: Date?
    /// The reply to the submitted turn has started (she got busy), so her going quiet means she finished.
    private var replyStarted = false

    public init(timing: Timing = Timing()) { self.timing = timing }

    public mutating func handle(_ event: Event, at now: Date) -> [Effect] {
        switch event {
        case .keyDown:
            keyDownAt = now
            chord = false
            guard phase.isIdle else { return [] }
            buffering = true
            return [.buffer]
        case .otherKey:
            guard keyDownAt != nil, !chord else { return [] }
            chord = true
            return discard()
        case .keyUp:
            guard let down = keyDownAt else { return [] }
            keyDownAt = nil
            if chord || now.timeIntervalSince(down) > timing.tapMax { return discard() }
            buffering = false
            return tap(at: now)
        case .tap:
            return tap(at: now)
        case .speechStarted:
            switch phase {
            case .listening(_, let since): phase = .listening(heard: true, since: since)
            case .cooldown, .followUp, .replying: phase = .listening(heard: true, since: now)
            case .idle: break
            }
            return []
        case .speechStopped:
            guard case .listening = phase else { return [] }
            if timing.cooldown > 0 {
                phase = .cooldown(since: now, until: now.addingTimeInterval(timing.cooldown))
                return []
            }
            return submit(at: now)
        case .assistant(let busy):
            switch phase {
            case .replying:
                if busy { replyStarted = true } else if replyStarted { return finishReply(at: now) }
            case .followUp where busy, .listening(heard: false, _) where busy:
                // She answers something else (a typed message, an agent report): that's her reply.
                phase = .replying(since: now)
                replyStarted = true
            case .idle where busy:
                // She speaks up by herself (an agent report): show it, and let you answer in the follow-up.
                phase = .replying(since: now)
                replyStarted = true
                return [.open]
            default:
                break
            }
            return []
        case .dismiss:
            return phase.isIdle ? [] : close()
        case .reset:
            phase = .idle
            handsFree = false
            replyStarted = false
            buffering = false
            return []
        case .tick:
            return tick(at: now)
        }
    }

    /// How far the cooldown has run, 0...1, while it runs.
    public func cooldownProgress(at now: Date) -> Double? {
        guard case .cooldown(let since, let until) = phase else { return nil }
        return Self.fraction(now, since, until)
    }

    /// How much of the follow-up window is left, 1...0, while it runs.
    public func followUpRemaining(at now: Date) -> Double? {
        guard case .followUp(let since, let until) = phase else { return nil }
        return 1 - Self.fraction(now, since, until)
    }

    private static func fraction(_ now: Date, _ since: Date, _ until: Date) -> Double {
        let total = until.timeIntervalSince(since)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(since) / total))
    }

    private mutating func discard() -> [Effect] {
        guard buffering else { return [] }
        buffering = false
        return [.discard]
    }

    private mutating func tap(at now: Date) -> [Effect] {
        let double = lastTap.map { now.timeIntervalSince($0) <= timing.doubleTap } ?? false
        lastTap = double ? nil : now // a third tap starts a new pair
        if double, !phase.isIdle {
            handsFree.toggle()
            // Leaving hands-free ends the conversation; entering it keeps listening.
            return handsFree ? [] : close()
        }
        switch phase {
        case .idle:
            phase = .listening(heard: false, since: now)
            return [.open]
        case .listening(let heard, _):
            // Nothing said yet: you changed your mind. Mid-sentence, or hands-free: keep listening.
            return heard || handsFree ? [] : close()
        case .cooldown:
            return submit(at: now) // you're done: no need to wait out the cooldown
        case .replying:
            phase = .listening(heard: false, since: now)
            replyStarted = false
            return [.bargeIn]
        case .followUp:
            return handsFree ? [] : close()
        }
    }

    private mutating func submit(at now: Date) -> [Effect] {
        phase = .replying(since: now)
        replyStarted = false
        return [.submit]
    }

    private mutating func finishReply(at now: Date) -> [Effect] {
        replyStarted = false
        phase = handsFree ? .listening(heard: false, since: now)
                          : .followUp(since: now, until: now.addingTimeInterval(timing.followUp))
        return []
    }

    private mutating func close() -> [Effect] {
        phase = .idle
        handsFree = false
        replyStarted = false
        return [.close]
    }

    private mutating func tick(at now: Date) -> [Effect] {
        switch phase {
        case .idle:
            return []
        case .listening(let heard, let since):
            guard !heard, !handsFree, now.timeIntervalSince(since) >= timing.listenTimeout else { return [] }
            return close()
        case .cooldown(_, let until):
            return now >= until ? submit(at: now) : []
        case .replying(let since):
            // No reply ever came (an empty turn, a refused request): stop waiting, like after a reply.
            guard !replyStarted, now.timeIntervalSince(since) >= timing.replyTimeout else { return [] }
            return finishReply(at: now)
        case .followUp(_, let until):
            return now >= until ? close() : []
        }
    }
}

/// The words that end a conversation, as a whole turn ("that's all", "thanks, that's all for now").
public enum DismissPhrase {
    static let phrases = ["that's all", "that is all", "that'll be all", "that will be all", "we're done", "we are done",
                          "nothing else", "goodbye", "bye bye"]

    public static func matches(_ text: String) -> Bool {
        let said = WakePhrase.normalize(text)
        guard !said.isEmpty, said.split(separator: " ").count <= 8 else { return false }
        return phrases.contains { said.contains(WakePhrase.normalize($0)) }
    }
}

/// Whether a running transcript ends with the wake phrase. Recognizers hear "hey" as "hi", "hay" or "a", so the
/// first word of a "hey …" phrase may be any of those; the rest must match word for word.
public enum WakePhrase {
    public static let `default` = "Hey Companion"

    public static func matches(_ transcript: String, phrase: String) -> Bool {
        let wanted = normalize(phrase).split(separator: " ").map(String.init)
        let heard = normalize(transcript).split(separator: " ").map(String.init)
        guard !wanted.isEmpty, heard.count >= wanted.count else { return false }
        let greetings: Set<String> = ["hey", "hi", "hay", "a", "hei", "heh"]
        for start in 0...(heard.count - wanted.count) {
            let window = Array(heard[start..<(start + wanted.count)])
            let same = zip(window, wanted).enumerated().allSatisfy { index, pair in
                pair.0 == pair.1 || (index == 0 && wanted[0] == "hey" && greetings.contains(pair.0))
            }
            if same { return true }
        }
        return false
    }

    /// Lowercased words, apostrophes kept ("that's"), everything else that isn't a letter or digit a space.
    public static func normalize(_ text: String) -> String {
        let kept: [Character] = text.lowercased().map { c in
            if c == "’" { return "'" }
            return c.isLetter || c.isNumber || c == "'" ? c : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
