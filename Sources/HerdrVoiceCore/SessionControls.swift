import Foundation

/// The companion's session controls (mute, pause, stop speaking, connect), derived from the session in one place so
/// the chat's control bar, the orb's menu and the menu bar agree on what each one says and whether it applies.
public struct SessionControls: Equatable, Sendable {
    /// The connection, as the controls describe it.
    public enum Link: Equatable, Sendable {
        /// A session is open or opening.
        case connected
        /// Closed because nobody was talking; speech, typing or an agent report reopens it.
        case idle
        /// Closed and not back yet: a drop backing off, or retries given up.
        case offline
        /// Closed by the user; only Connect or a typed message reopens it.
        case disconnected
    }

    /// There is a session to control (there is none until the provider has a key).
    public var available: Bool
    public var link: Link
    public var muted: Bool
    public var paused: Bool
    /// The voice is audible right now.
    public var speaking: Bool

    public init(available: Bool = false, link: Link = .offline, muted: Bool = false, paused: Bool = false,
                speaking: Bool = false) {
        self.available = available
        self.link = link
        self.muted = muted
        self.paused = paused
        self.speaking = speaking
    }

    /// `open`: the session's status is anything but disconnected.
    public static func link(open: Bool, dormant: Bool, disconnectedByUser: Bool) -> Link {
        if disconnectedByUser { return .disconnected }
        if open { return .connected }
        return dormant ? .idle : .offline
    }

    /// The mic is heard: not muted, not paused, and not disconnected on purpose.
    public var listening: Bool { available && !muted && !paused && link != .disconnected }

    /// One word for where things stand, the most binding first: a disconnect outranks a pause, a pause a mute.
    public var state: String {
        guard available else { return "No session" }
        if link == .disconnected { return "Disconnected" }
        if paused { return "Paused" }
        if muted { return "Muted" }
        return switch link {
        case .connected: "Connected"
        case .idle: "Idle"
        case .offline: "Offline"
        case .disconnected: "Disconnected"
        }
    }

    /// The state in a sentence, for a tooltip.
    public var detail: String {
        guard available else { return "No voice session yet: add the provider's key in Settings." }
        let session = switch link {
        case .connected: "The session is open."
        case .idle: "The session is closed while it's quiet; it opens when you speak or type."
        case .offline: "The session is offline; Connect tries again now."
        case .disconnected: "Disconnected: nothing reopens the session until you connect or type a message."
        }
        var parts = [session]
        if paused { parts.append("Paused: the mic is off, and replies and agent reports wait until you resume.") }
        if muted { parts.append("Muted: the mic is off; the voice can still talk.") }
        return parts.joined(separator: " ")
    }

    public var muteTitle: String { muted ? "Unmute" : "Mute" }
    public var muteSymbol: String { muted ? "mic.slash.fill" : "mic.fill" }
    public var pauseTitle: String { paused ? "Resume" : "Pause" }
    public var pauseSymbol: String { paused ? "play.fill" : "pause.fill" }
    public static let stopTitle = "Stop speaking"
    public static let stopSymbol = "stop.fill"
    /// Disconnect while the session is up or idle (an idle one reopens when you speak, so it needs closing too);
    /// Connect once it's offline or disconnected, which opens it now.
    public var connectCloses: Bool { link == .connected || link == .idle }
    public var connectTitle: String { connectCloses ? "Disconnect" : "Connect" }
    public var connectSymbol: String { connectCloses ? "phone.down.fill" : "phone.fill" }
    /// Stop speaking only means something while the voice is audible.
    public var canStopSpeaking: Bool { available && speaking }

    // What a press asks for. Each control asks for the state its title promised when it was shown ("Mute" mutes,
    // "Unmute" unmutes), never for the opposite of whatever holds when the press lands: a press that arrives twice
    // (a double click, the menu and the hotkey at once, two apps on one hotkey) then lands on the same state twice,
    // where a toggle flipped it straight back.

    public var mutePress: ControlPress { .mute(!muted) }
    public var pausePress: ControlPress { .pause(!paused) }
    public var connectPress: ControlPress { .connect(!connectCloses) }

    /// These controls once the session has done what `press` asks.
    public func applying(_ press: ControlPress) -> SessionControls {
        guard available else { return self }
        var next = self
        switch press {
        case .mute(let on): next.muted = on
        case .pause(let on): next.paused = on
        case .connect(let on):
            if on, link == .disconnected || link == .offline { next.link = .connected }
            if !on, link != .disconnected { next.link = .disconnected }
        }
        return next
    }
}

/// One press of a session control, with the state it asks for.
public enum ControlPress: Equatable, Sendable {
    case mute(Bool), pause(Bool), connect(Bool)
}

/// A hotkey is a toggle, so a second delivery of one press would undo the first: presses closer together than
/// `interval` count once. Nobody means two mutes a third of a second apart.
public struct PressDebounce: Sendable {
    public let interval: TimeInterval
    private var last = Date.distantPast

    public init(interval: TimeInterval = 0.35) { self.interval = interval }

    /// True if this press counts.
    public mutating func accept(at now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

/// Where an agent report (or a typed message) goes, given the session's controls.
public enum ReportDelivery: Equatable, Sendable {
    /// Into the live session, with a spoken reply.
    case send
    /// Into the outbox, until the session comes up or the pause ends.
    case hold
    /// Into the outbox, and the closed session is opened for it.
    case holdAndConnect

    /// `live`: the session is up and established. A pause holds everything; a closed session reopens for a report
    /// unless the user closed it, which only Connect or typing undoes.
    public static func route(paused: Bool, live: Bool, disconnected: Bool, disconnectedByUser: Bool) -> ReportDelivery {
        if paused { return .hold }
        if live { return .send }
        return disconnected && !disconnectedByUser ? .holdAndConnect : .hold
    }
}

extension Activity {
    /// `mood` under the companion's controls: a session the user disconnected is offline even while muted, and a
    /// paused one is muted (nothing listens, nothing is said).
    public static func mood(controls c: SessionControls, loading: Bool, agentsWorking: Bool, micQuiet: Bool) -> Mood {
        guard c.available, c.link != .disconnected else { return .offline }
        return mood(loading: loading, disconnected: c.link != .connected, dormant: c.link == .idle,
                    muted: c.muted || c.paused, speaking: c.speaking && !c.paused,
                    agentsWorking: agentsWorking, micQuiet: micQuiet)
    }
}
