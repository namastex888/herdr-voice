import Foundation
import HerdrVoiceCore
import os

/// One realtime voice session: streams mic audio up, plays assistant audio, runs Herdr tools.
/// Main-actor state, except the mic path (`micChunk`), which runs on the mic queue every 20 ms. It reaches only
/// `micShared`, `micLocal`, `audio` and constants, and streams through the socket `micShared` holds for it.
@MainActor public final class Realtime {
    public enum Status { case connecting, live, disconnected }

    /// What tools run through: every Herdr tool for the plugin, the skill registry for the companion.
    private let host: ToolHost
    /// The voice's standing instructions, sent with every setup (see `setInstructions`).
    private var instructions: String
    /// The next renewal starts a fresh session (with the recap) instead of resuming, so new instructions take hold.
    private var renewFresh = false
    /// What the voice is asked to say when a session first comes up (or after a provider switch). The companion
    /// updates it as it learns: only a new hire's first session greets as one.
    public var greeting: String
    /// The tools offered now: the host's, or the narrower set routed for the current turn (see `setTools`).
    private var tools: ToolList
    /// What the session is doing, for a UI: both sides of the conversation, tool calls and status lines.
    public var onEvent: ((SessionEvent) -> Void)?
    /// Each of the user's turns, spoken or typed, as soon as its text is known (the companion routes skills on it).
    public var onUserTurn: ((String) -> Void)?

    public private(set) var provider: Provider { didSet { capabilities = provider.capabilities } }
    /// The provider's protocol differences. Follows `provider` rather than `wire`: while a switch is still preparing,
    /// the mic and the events it raises already belong to the new provider, though its wire doesn't exist yet.
    private var capabilities: WireCapabilities
    private var key: String
    private var voice: String
    private var requestOverride: URLRequest?
    nonisolated public let audio = Audio()
    private var socket: (any SessionSocket)?
    /// Opens a connection's socket: a URLSession WebSocket, or a test's fake.
    private let makeSocket: @MainActor (URLRequest) -> any SessionSocket
    /// The provider's wire protocol for the current connection (see Wire). Replaced on every connect.
    private var wire: Wire
    /// Gemini: resumes the previous session, context included, on the next connection.
    private var resumeHandle: String?
    /// Whether this connection resumed a session with its context (then no recap is needed).
    private var resumedWithContext = false
    /// Providers without explicit replies (Gemini) answer as soon as they get a tool response or a completed
    /// text turn, so those wait here until the reply scheduler says a reply may start.
    private var pendingOutputs: [ToolOutput] = []
    private var pendingTexts: [String] = []
    /// Gemini's goAway arrived while something was still being said: renew once it's done.
    private var renewWhenIdle = false
    public private(set) var status = Status.disconnected { didSet { syncSendGate() } }
    public private(set) var muted = false { didSet { syncSendGate() } }
    /// Held by the user: the mic is off, speech is cut, and replies and agent reports wait for `resume()`.
    public private(set) var paused = false { didSet { syncSendGate() } }
    /// Closed by the user: speech, agent reports and retries don't reopen it; `reconnect()` or a typed message does.
    public private(set) var disconnectedByUser = false { didSet { syncSendGate() } }
    /// The mic is off: muted, paused, or disconnected on purpose (its speech would have nowhere to go).
    private var micOff: Bool { muted || paused || disconnectedByUser }
    /// Between conversations (the companion's tap-to-talk and wake word): the mic is off for the session, so nothing
    /// is streamed or held and speech doesn't reopen it, though the gate keeps learning the room's noise and its last
    /// moment of audio, so the words right after a tap aren't lost. Not a control: the state shows as Idle.
    public private(set) var standby = false { didSet { syncSendGate() } }
    /// Nothing from the mic reaches a session: off, or on standby. Voice processing is bypassed meanwhile.
    private var micIdle: Bool { micOff || standby }
    /// The companion's tap-to-talk: the session, not the provider, decides when to answer a spoken turn
    /// (`submitTurn`), where the provider allows it (`capabilities.deferredReplies`); elsewhere (Grok, Gemini, Local)
    /// the provider answers each turn as before. Sent right after every setup, and at once when changed mid-session.
    public var deferReplies = false {
        didSet {
            guard deferReplies != oldValue else { return }
            syncSendGate()
            if capabilities.deferredReplies, status == .live { send(.deferReplies(deferReplies)) }
        }
    }
    /// The activation key is down and not yet a tap: the mic's speech is kept here, never streamed, and doesn't open
    /// a session (`buffer`).
    public private(set) var buffering = false { didSet { syncSendGate() } }
    /// `start()` ran: the audio engine exists, so voice processing can be switched.
    private var audioStarted = false
    /// Replies to spoken turns wait for `submitTurn`.
    private var deferring: Bool { deferReplies && capabilities.deferredReplies }
    /// A turn submitted before its session was up, sent once it is (right after the speech held meanwhile).
    private var submitWhenUp = false
    /// You started (true) or stopped (false) talking, as the session sees it: the provider's speech detection once the
    /// mic's speech sensor agrees (see `confirmSpeech`), or the gate where the session marks speech itself. Noise and
    /// her own echo never raise it. The companion's tap-to-talk times its cooldown and follow-up from it.
    public var onSpeech: ((Bool) -> Void)?
    /// Tool calls made after an agent report but before the developer speaks again are not user-initiated.
    private var lastSpeechStart = Date.distantPast
    private var lastReport = Date.distantPast
    /// Agents currently being watched in the background.
    public private(set) var busyAgents = Set<String>()
    /// Pane watches running in the background. Unlike busy agents they don't count as work: a watch can wait an
    /// hour for a dev server, and the orb shouldn't churn or the session stay open all that time.
    private var watchedPanes = Set<String>()
    /// A response is being generated; `response.cancel` is only valid while this is true.
    /// One response at a time: every reply request goes through here (see ResponseScheduler).
    private var replies = ResponseScheduler()
    private var responseActive: Bool { replies.responseActive }
    /// A response.create is out and the provider hasn't confirmed it; an error then means it was refused.
    private var awaitingCreated = false
    /// Tool calls repeated by the model within a few seconds are answered, not run again.
    private var deduper = CallDeduper()
    /// Whether the developer's latest speech began while the assistant was audible. A "yes" like that can be the
    /// assistant's own voice leaking into the mic, so it must not confirm anything.
    private var speechOverlappedPlayback = false
    /// The provider heard speech start and not yet stop: when, and whether the mic's speech sensor confirmed it
    /// (`counted`). Until then it is taken for noise or her echo.
    private var providerSpeech: (since: Date, counted: Bool)?
    /// The mic's speech sensor hears someone talking now.
    private var micHearsSpeech = false
    /// The provider took your turn for over while the sensor still heard you: it ends when the sensor hears you stop.
    private var speechEndPending = false
    /// Set when the developer stops talking, until the reply starts; expires in case no reply comes.
    private var awaitingReplySince: Date?
    private var toolsRunning = 0

    /// Something is actively working: the voice model processing (between your speech and its voice, or
    /// between tool steps), a Herdr tool call running, or a coding agent busy with work you sent.
    public var thinking: Bool {
        Activity.isThinking(awaitingReplySince: awaitingReplySince, now: Date(), responseActive: responseActive,
                            speaking: audio.isSpeaking, droppingAudio: droppingAudio,
                            toolsRunning: toolsRunning, busyAgents: busyAgents.count)
    }
    /// Code-level enforcement of the speaking style for the reply being generated.
    private var policy = SpeechPolicy()
    /// What the current reply read aloud that it shouldn't have; corrected once the reply is over.
    private var leaked: String?
    /// One correction per turn of yours, so the notes don't pile up.
    private var correctedLeak = false
    /// After a stop, audio still in flight for the cancelled response is dropped until the next response starts.
    private var droppingAudio = false

    // Reconnecting. Providers close idle sessions (xAI after 15 minutes), networks drop, and a Mac that slept can
    // leave a dead socket behind, so the session is kept alive and renewed automatically.
    /// Bumped per connect so callbacks and scheduled retries that belong to an older socket are ignored.
    private var connection = 0
    /// True once the server has spoken on this socket; until then a close counts as a failed attempt, and mic
    /// audio isn't streamed (it would only pile up send errors against a socket that isn't open).
    private var established = false { didSet { syncSendGate() } }
    /// Consecutive attempts that failed before a session came up.
    private var attempts = 0
    /// Set when the provider announces why it's closing, read when the socket then fails.
    private var closeReason: Reconnect.Reason?
    private var hadSession = false
    /// Greet on the next session that comes up: set at launch and when the model is switched, not for reconnects
    /// (those are silent, and a session reopened by your speech shouldn't talk over you).
    private var greetNext = true
    /// What was said, replayed into a renewed session so it still knows the conversation.
    private var recap = Recap()
    /// Agent reports that arrived while offline, delivered once the next session is up.
    private var outbox: [String] = []
    private var keepalive: DispatchSourceTimer?
    private var pongPending = false

    // Speech-gated streaming. Providers bill per minute of audio, and an always-open mic streams every unmuted
    // minute. Only speech is sent (SpeechGate), and a quiet session is closed and reopened when you next speak.
    // HERDR_VOICE_STREAM=always restores continuous streaming.
    private nonisolated let gated = ProcessInfo.processInfo.environment["HERDR_VOICE_STREAM"] != "always"
    /// A session with no speech for this long, and nothing speaking or running, is closed until you speak.
    nonisolated static let quietClose: TimeInterval = 180
    /// How long the provider's "speech started" waits for the mic's speech sensor to agree before it is taken for
    /// noise or echo.
    nonisolated static let bargeInWindow: TimeInterval = 1.5
    /// HERDR_VOICE_GATE_DEBUG=1: log gate openings/closings and a level meter every 5 s, to tune any mic.
    private nonisolated let gateDebug = ProcessInfo.processInfo.environment["HERDR_VOICE_GATE_DEBUG"] == "1"
    private nonisolated let echoRatio = EchoGuard.ratio(environment: ProcessInfo.processInfo.environment)
    /// The mic queue's own state: the speech gate and the echo and meter bookkeeping around it. Only the mic queue
    /// (and init) touch it, so its lock is never contended.
    private struct MicLocal {
        /// HERDR_VOICE_GATE_THRESHOLD pins the opening level for unusual hardware.
        var gate = SpeechGate<String>(
            overrideThreshold: ProcessInfo.processInfo.environment["HERDR_VOICE_GATE_THRESHOLD"].flatMap(Float.init))
        /// Tells speech from noise for barge-in and turn-taking.
        var sensor: any SpeechSensor
        var echoReference: Float = 0
        var meterPeak: Float = 0
        var meterChunks = 0

        /// What the gate sees, so any mic can be checked and tuned. Returns the lines to log.
        mutating func meter(level: Float, playback: Float, opened: Bool, closed: Bool) -> [String] {
            let floor = gate.noiseFloor, open = gate.openThreshold
            var lines: [String] = []
            if opened || closed {
                lines.append(String(format: "🎚  gate %@  level %.4f  floor %.4f  open at %.4f  playback %.4f",
                                    opened ? "OPEN " : "close", level, floor, open, playback))
            }
            meterPeak = max(meterPeak, level)
            meterChunks += 1
            guard meterChunks >= 250 else { return lines } // every 5 s
            lines.append(String(format: "🎚  floor %.4f  open at %.4f  peak %.4f (last 5 s)", floor, open, meterPeak))
            meterPeak = 0
            meterChunks = 0
            return lines
        }
    }
    private nonisolated let micLocal: OSAllocatedUnfairLock<MicLocal>
    /// Where the mic queue streams to: the current connection's wire and socket, read together under `micShared`.
    private struct MicLink {
        let wire: Wire
        let socket: (any SessionSocket)?
        let connection: Int
        let onsets: Bool
    }
    /// Shared between the mic queue and main.
    private struct MicShared {
        /// The mic is off (`micOff`: muted, paused or disconnected on purpose): nothing is gated, held or sent.
        var muted = false
        /// The provider detects no speech (`explicitSpeechOnsets`): the gate marks utterances and speech events.
        var onsets = false
        /// On standby: the gate keeps learning, but nothing is sent, held or reopens a session.
        var standby = false
        var mayStream = false
        /// The provider has heard speech start and not yet end: keep streaming so it sees the turn finish.
        var midTurn = false
        var lastSpeech = Date()
        /// Speech captured while the session was closed or reopening, sent once it's up (at most 10 s).
        var held = HeldMicAudio()
        /// The current connection's wire and socket, for streaming audio from the mic queue. Main replaces the
        /// socket on every connect, so the mic queue must never read the session's own `socket`.
        var wire: Wire?
        var socket: (any SessionSocket)?
        var connection = 0

        var link: MicLink? {
            wire.map { MicLink(wire: $0, socket: socket, connection: connection, onsets: onsets) }
        }
    }
    private nonisolated let micShared = OSAllocatedUnfairLock(initialState: MicShared())
    /// Closed on purpose because nobody was talking; any speech (or an agent report) reopens it.
    public private(set) var dormant = false
    /// A reconnect is already scheduled by the backoff.
    private var retryPending = false
    public private(set) var providerPreparing = false
    /// Local mode: the helper's connection was lost, so its port is dead and the next connect relaunches it.
    private var connectionLost = false
    /// Relaunches the Local OpenLive helper off the main queue, then calls completeProviderSwitch with its new port,
    /// or localRelaunchFailed.
    public var relaunchLocalHelper: (() -> Void)?
    private var quietTimer: DispatchSourceTimer?

    public init(provider: Provider, key: String, voice: String, request: URLRequest? = nil,
                host: ToolHost = HerdrToolHost(), instructions: String = voiceInstructions,
                greeting: String = Greeting.prompt,
                speechSensor: any SpeechSensor = LoudnessSensor(),
                socket makeSocket: @escaping @MainActor (URLRequest) -> any SessionSocket = {
                    URLSession.shared.webSocketTask(with: $0)
                }) {
        self.micLocal = OSAllocatedUnfairLock(initialState: MicLocal(sensor: speechSensor))
        self.makeSocket = makeSocket
        self.provider = provider
        self.key = key
        self.voice = voice
        self.requestOverride = request
        self.host = host
        self.instructions = instructions
        self.greeting = greeting
        self.tools = host.tools
        // Local with no runtime yet: stay closed until completeProviderSwitch brings the loaded runtime's request.
        // (The helper process, not the protocol: nothing to connect to until it is up.)
        self.providerPreparing = provider == .local && request == nil
        let wire = provider.makeWire()
        self.wire = wire
        self.capabilities = wire.capabilities
        let onsets = wire.capabilities.explicitSpeechOnsets
        let policy: SpeechGate<String>.Policy = onsets ? .local : .cloud
        micLocal.withLock { $0.gate.policy = policy }
        micShared.withLock { $0.onsets = onsets }
        audio.onMic = { [weak self] b64, level in self?.micChunk(b64, level: level) }
    }

    public func start() throws {
        try audio.start()
        audioStarted = true
        if standby { audio.setMuted(micIdle) } // set before the engine existed
        if !providerPreparing && !standby { connect() }
        if gated { startQuietTimer() }
    }

    /// What the gate made of one mic chunk.
    private struct GateStep {
        var chunks: [String] = []
        var useGate = false
        var opened = false
        var closed = false
        /// The speech sensor heard speech start (true) or stop (false) with this chunk.
        var speech: Bool?
        var meterLines: [String] = []
    }

    /// On the mic queue, every 20 ms.
    private nonisolated func micChunk(_ b64: String, level: Float) {
        // With explicit onsets the gate is the only speech detector: always on, never held open by the provider, and
        // its openings and closings are the utterance boundaries.
        let (muted, midTurn, onsets, standby) = micShared.withLock { ($0.muted, $0.midTurn, $0.onsets, $0.standby) }
        let playback = audio.outLevel
        let gated = gated, gateDebug = gateDebug, echoRatio = echoRatio
        let gateStep = micLocal.withLock { m -> GateStep? in
            let wantedPolicy: SpeechGate<String>.Policy = onsets ? .local : .cloud
            if m.gate.policy != wantedPolicy {
                m.gate.policy = wantedPolicy
                m.gate.reset()
            }
            if muted {
                m.gate.reset()
                m.sensor.reset()
                return nil
            }
            var step = GateStep()
            let wasOpen = m.gate.isOpen
            // Her own voice leaking back into the mic is never you, whoever the provider: while she plays, input below
            // `echoRatio` × her playback counts as the room's noise.
            m.echoReference = EchoGuard.reference(previous: m.echoReference, playback: playback)
            let gateLevel = EchoGuard.level(level, playback: m.echoReference, floor: m.gate.noiseFloor, ratio: echoRatio)
            let loud = gateLevel > m.gate.openThreshold
            step.useGate = gated || onsets
            step.chunks = step.useGate ? m.gate.process(b64, level: gateLevel, holdOpen: onsets ? false : midTurn) : [b64]
            step.opened = m.gate.isOpen && !wasOpen
            step.closed = wasOpen && !m.gate.isOpen
            if gateDebug && step.useGate {
                step.meterLines = m.meter(level: level, playback: playback, opened: step.opened, closed: step.closed)
            }
            // On standby the gate has learned from this chunk; nothing goes anywhere.
            if standby { return nil }
            step.speech = m.sensor.hear(b64, aboveEcho: level >= m.echoReference * echoRatio, loud: loud)
            return step
        }
        guard let gateStep else { return }
        for line in gateStep.meterLines { DispatchQueue.main.async { log(line) } }
        if let speech = gateStep.speech { DispatchQueue.main.async { self.micHeardSpeech(speech) } }
        let chunks = gateStep.chunks, useGate = gateStep.useGate, opened = gateStep.opened, closed = gateStep.closed
        guard !chunks.isEmpty else { return }
        let stream = { [weak self] (link: MicLink) in
            guard let self else { return }
            if useGate { self.micShared.withLock { $0.lastSpeech = Date() } }
            let send = { (command: WireCommand) in
                if let socket = link.socket { self.transmit(link.wire.encode(command), on: socket, connection: link.connection) }
            }
            if link.onsets && opened {
                send(.inputStarted(utteranceID: UUID().uuidString))
                DispatchQueue.main.async { self.handle(.speechStarted) }
            }
            chunks.forEach { send(.appendAudio($0)) }
            // The gate just closed: tell the provider the stream paused (Gemini ends the turn on it).
            if closed {
                send(.audioPaused)
                if link.onsets { DispatchQueue.main.async { self.handle(.speechStopped) } }
            }
        }
        if let link = micShared.withLock({ $0.mayStream ? $0.link : nil }) {
            stream(link)
            return
        }
        // No session right now (closed while quiet, warming, or reconnecting): retain at most ten seconds. Muted since
        // this chunk was read: it is dropped, never kept for a session.
        let held = micShared.withLock { state -> (link: MicLink?, onsets: Bool)? in
            if state.muted { return nil }
            if state.mayStream {
                return (state.link, state.onsets)
            }
            if state.onsets {
                state.held.appendLocal(chunks, opened: opened, closed: closed, utteranceID: UUID().uuidString)
            } else {
                state.held.appendCloud(chunks, opened: opened, closed: closed)
            }
            state.lastSpeech = Date()
            return (nil, state.onsets)
        }
        guard let held else { return }
        if let link = held.link {
            stream(link)
            return
        }
        if held.onsets && opened { DispatchQueue.main.async { self.handle(.speechStarted) } }
        if held.onsets && closed { DispatchQueue.main.async { self.handle(.speechStopped) } }
        DispatchQueue.main.async { self.wake() }
    }

    /// Speech while there's no session. Reopens a session that was closed on purpose (quiet), or tries once more
    /// after giving up. Never while a retry is already scheduled: speech must not defeat the backoff, or every
    /// sound during an outage would hammer the provider with connects.
    private func wake() {
        guard status == .disconnected, !micIdle, !buffering, !retryPending, !providerPreparing else { return }
        if dormant {
            dormant = false
            attempts = 0
            note("🎙  heard you; reopening the session")
        }
        connect()
    }

    private func activateHeldAudio() -> Bool {
        let wire = wire, socket = socket, connection = connection, live = status == .live
        // A key press still unresolved (a session came up for something else): keep its audio for the tap.
        guard !buffering else { return false }
        return micShared.withLock { s in
            let held = s.held.drain()
            // Kept before a mute (or a pause, or standby): it never leaves, whatever brought the session up.
            guard !s.muted, !s.standby else {
                s.mayStream = false
                return false
            }
            let hadAudio = held.utteranceID != nil || !held.chunks.isEmpty
            var frames: [[String: Any]] = []
            if let id = held.utteranceID {
                frames += wire.encode(.inputStarted(utteranceID: id))
            }
            held.chunks.forEach { frames += wire.encode(.appendAudio($0)) }
            if held.closed { frames += wire.encode(.audioPaused) }
            // Sending the backlog and enabling live streaming under the same lock keeps new mic packets behind it.
            if let socket { self.transmit(frames, on: socket, connection: connection) }
            s.mayStream = !s.muted && !s.standby && live
            return hadAudio
        }
    }

    /// Every 5 s: close a metered session nobody has talked to for `quietClose`, if nothing is speaking or running.
    /// A pause doesn't keep it open: its queued reports reopen the session on resume. A reply held back by the pause
    /// (a tool's result) does, like a reply in progress, since it can only be said in this session.
    private func startQuietTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.status == .live, self.established, self.capabilities.metered else { return }
            let quietFor = Date().timeIntervalSince(self.micShared.withLock { $0.lastSpeech })
            guard quietFor > Self.quietClose, !self.responseActive, !self.audio.isSpeaking,
                  self.toolsRunning == 0, self.outbox.isEmpty || self.paused,
                  !(self.paused && self.replies.replyWanted) else { return }
            self.goDormant("no speech for \(Int(Self.quietClose / 60)) min")
        }
        timer.resume()
        quietTimer = timer
    }

    private func goDormant(_ why: String, until: String? = nil, quietly: Bool = false) {
        dormant = true
        if let s = socket {
            socket = nil
            s.close(.normalClosure)
        }
        keepalive?.cancel()
        keepalive = nil
        status = .disconnected
        replies.reset()
        awaitingCreated = false
        awaitingReplySince = nil
        micShared.withLock { $0.midTurn = false }
        forgetSpeech()
        submitWhenUp = false
        let line = "💤 \(why); session closed until \(until ?? (paused ? "you resume" : "you speak"))"
        if quietly { log(line) } else { note(line) }
    }

    public func connect() {
        guard !providerPreparing else { return }
        // Closed by the user: whatever asked (a provider switch, a stray retry), it stays closed until reconnect().
        guard !disconnectedByUser else { return note("⏏  still disconnected; Connect opens \(provider.menuTitle)") }
        retryPending = false
        dormant = false
        if Reconnect.relaunchesHelper(provider: provider, connectionLost: connectionLost), let relaunchLocalHelper {
            connectionLost = false
            providerPreparing = true
            requestOverride = nil
            note("↻ relaunching Local OpenLive")
            return relaunchLocalHelper()
        }
        micShared.withLock { $0.midTurn = false }
        forgetSpeech()
        connection += 1
        established = false
        closeReason = nil
        status = .connecting
        wire = provider.makeWire()
        pendingOutputs.removeAll()
        pendingTexts.removeAll()
        renewWhenIdle = false
        let task = makeSocket(requestOverride ?? provider.request(key: key))
        socket = task
        let newWire = wire, id = connection
        micShared.withLock {
            $0.wire = newWire
            $0.socket = task
            $0.connection = id
        }
        task.resume()
        // New instructions need a fresh session: a resumed one would keep the old ones. The recap carries the context.
        let handle = wire.capabilities.nativeResumption && !renewFresh ? resumeHandle : nil
        renewFresh = false
        resumedWithContext = handle != nil
        // A provider that can't swap tools later starts with all of them.
        let offered = wire.capabilities.dynamicTools ? tools : host.tools
        send(.setup(instructions: instructions, voice: voice, resumeHandle: handle, tools: offered))
        if deferring { send(.deferReplies(true)) } // before any audio, so no turn is answered by itself
        status = .live
        if hadSession || attempts > 0 {
            note("↻ reconnecting to \(provider.rawValue)")
        } else {
            note("● connecting to \(provider.rawValue) — speak any time, \(Hotkey.label) mutes, Esc stops speech")
        }
        receive(task)
        startKeepalive(task)
    }

    /// The first server event on a socket (with a `setupHandshake`, the setup's acknowledgement): the session is up.
    private func sessionEstablished() {
        note(hadSession ? "↻ reconnected" : "● connected")
        // Speech held while the session reopened goes first, before live audio starts flowing.
        let heardDuringHandshake = activateHeldAudio()
        established = true
        attempts = 0
        // A session resumed with its context (Gemini) already remembers the conversation.
        if hadSession, !resumedWithContext, let context = recap.message {
            send(.userText(context, expectsReply: false))
        }
        hadSession = true
        // With explicit onsets, speech held through the handshake was just replayed as a whole utterance, and the
        // session asks for its reply itself: you spoke first, so that reply replaces the greeting.
        let answeringYou = (capabilities.explicitSpeechOnsets || deferring) && heardDuringHandshake
        if greetNext, !answeringYou {
            greetNext = false
            addReplyText(greeting)
            if replies.wantReply() { requestResponse() }
        } else if answeringYou {
            greetNext = false
        }
        if submitWhenUp {
            submitWhenUp = false
            submitTurn()
        }
        guard !paused else { return } // the outbox waits for resume()
        flushOutbox()
    }

    /// Sends the reports that waited (offline or paused) and asks for one reply to them.
    private func flushOutbox() {
        guard !outbox.isEmpty else { return }
        outbox.forEach(addReplyText)
        outbox.removeAll()
        if replies.wantReply() { requestResponse() }
    }

    private func connectionLost(_ task: any SessionSocket, reason: Reconnect.Reason, detail: String) {
        guard task === socket else { return }
        socket = nil
        task.close(.goingAway)
        keepalive?.cancel()
        keepalive = nil
        status = .disconnected
        replies.reset()
        awaitingCreated = false
        awaitingReplySince = nil
        if !established {
            attempts += 1
            resumeHandle = nil // if a resumption was refused, the next attempt starts a fresh session
        }
        connectionLost = true
        // The provider closed a quiet session: nothing to reconnect for until someone speaks.
        if gated && reason == .sessionEnded && !muted {
            dormant = true
            note("💤 \(detail); reopens when you speak")
            return
        }
        scheduleRetry(reason: reason, detail: detail)
    }

    /// The helper relaunch failed: counts as a failed attempt and backs off like a drop.
    public func localRelaunchFailed(_ detail: String) {
        providerPreparing = false
        connectionLost = true
        attempts += 1
        scheduleRetry(reason: .dropped, detail: detail)
    }

    private func scheduleRetry(reason: Reconnect.Reason, detail: String) {
        guard !disconnectedByUser else { return }
        guard let delay = Reconnect.delay(reason: reason, attempt: attempts, muted: muted) else {
            note(muted ? "… \(detail); reconnects when you unmute"
                      : "✖ \(detail); gave up after \(attempts) tries; speak to try again")
            return
        }
        note(delay == 0 ? "↻ \(detail)" : "↻ \(detail); reconnecting in \(Int(delay)) s")
        let id = connection
        retryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.connection == id, self.status == .disconnected else { return }
            self.connect()
        }
    }

    /// Pings every 20 s. A failed ping, or no pong by the next one, means the socket is dead (sleep, network
    /// change) even though no error surfaced, so reconnect instead of waiting forever.
    private func startKeepalive(_ task: any SessionSocket) {
        keepalive?.cancel()
        pongPending = false
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(2))
        timer.setEventHandler { [weak self, weak task] in
            guard let self, let task else { return }
            if self.pongPending {
                return self.connectionLost(task, reason: .dropped, detail: "no reply to keepalive")
            }
            self.pongPending = true
            task.ping { error in
                DispatchQueue.main.async {
                    self.pongPending = false
                    if let error { self.connectionLost(task, reason: .dropped, detail: "keepalive failed: \(error.localizedDescription)") }
                }
            }
        }
        timer.resume()
        keepalive = timer
    }

    /// Sends a conversation item that should get a spoken reply, or keeps it for the next session and makes sure
    /// one is coming: an agent report is worth reopening the session for, even while muted. Not while paused (it
    /// waits for resume) or disconnected by the user (it waits for reconnect).
    private func deliver(_ text: String) {
        switch ReportDelivery.route(paused: paused, live: status == .live && established,
                                    disconnected: status == .disconnected, disconnectedByUser: disconnectedByUser) {
        case .send:
            addReplyText(text)
            if replies.wantReply() { requestResponse() } // otherwise it joins the reply already on its way
        case .hold:
            outbox.append(text)
        case .holdAndConnect:
            outbox.append(text)
            attempts = 0
            connect()
        }
    }

    /// The mic queue reads these two under `micShared`: whether the mic is off, and whether it may stream now.
    private func syncSendGate() {
        let off = micOff, standby = standby
        // While buffering nothing streams, even to a session that happens to be up: the press may be ⌘C.
        let allowed = !off && !standby && !buffering && status == .live && established
        micShared.withLock {
            $0.muted = off
            $0.standby = standby
            $0.mayStream = allowed
            // Off means off: speech kept for a session (the activation key's buffer, a sentence held through a
            // reconnect) is dropped, or it would be replayed the moment one comes up.
            if off { $0.held.reset() }
        }
    }

    /// The tools to offer from the next turn on. Sent at once where the provider can swap tools mid-session;
    /// elsewhere the session keeps everything the host offers.
    public func setTools(_ list: ToolList) {
        tools = list
        guard wire.capabilities.dynamicTools, status == .live, established else { return }
        send(.updateTools(list))
    }

    /// Replaces the voice's standing instructions. Sent at once where the provider can change them mid-session;
    /// elsewhere the connection is renewed (right away, or once the current reply and tool calls finish) and the
    /// recap carries the conversation over.
    public func setInstructions(_ text: String) {
        guard text != instructions else { return }
        instructions = text
        guard status == .live else { return } // not set up yet: the next setup sends them
        if wire.capabilities.dynamicTools {
            send(.updateInstructions(text)) // on the same socket, so after a setup that is still being answered
            return
        }
        renewFreshWhenIdle()
    }

    /// Changes the voice from the next setup on. A live session can't change its voice once it has spoken, so the
    /// connection is renewed fresh (when idle) and the recap carries the conversation over.
    public func setVoice(_ name: String) {
        guard !name.isEmpty, name != voice else { return }
        voice = name
        guard status == .live else { return }
        renewFreshWhenIdle()
    }

    /// Renews into a fresh session (not a resumed one, which would keep the old setup): right away, or once the
    /// current reply and tool calls finish.
    private func renewFreshWhenIdle() {
        renewFresh = true
        if !established || responseActive || audio.isSpeaking || replies.callsInFlight > 0 {
            renewWhenIdle = true
        } else {
            renewConnection()
        }
    }

    /// A message typed into a chat. It is the user's own words, like speech: it counts as theirs for tool
    /// provenance, can answer a pending confirmation, and reopens a closed session.
    public func sendTyped(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastSpeechStart = Date()
        log("you:   \(text)")
        recap.add("you", text)
        onEvent?(.you(text))
        onUserTurn?(text)
        ConfirmGate.shared.heard(text)
        if StopCommand.matches(text) { return stopSpeech(reason: "you said stop") }
        // Typing is an explicit request, so it ends a pause or a disconnect; speech can't (the mic is off for both).
        if paused { resume() }
        if disconnectedByUser { reconnect() }
        deliver(text)
    }

    /// Logs a status line and shows it in a UI.
    private func note(_ line: String) {
        log(line)
        onEvent?(.note(line))
    }

    /// Closes the provider session cleanly so billing stops at once; call before exiting.
    public func shutdown() {
        note("👋 herdr-voice closed")
        guard let s = socket else { return }
        socket = nil
        s.close(.normalClosure)
    }

    /// The plugin's ⌥⌘M and orb click: mutes when unmuted, whatever the connection is doing (a session closed while
    /// quiet is its usual state between sentences, and a press that only re-armed it let the next sentence through);
    /// unmutes when muted.
    public func toggleMute() {
        setMuted(!muted)
    }

    /// Drops what the provider heard but hasn't answered, as the mic goes off.
    private func clearHeardInput() {
        send(.clearInput)
        // Clearing starts a new epoch: the provider drops the reply in progress without a response.done.
        if capabilities.turnEpochs {
            replies.reset()
            awaitingCreated = false
            awaitingReplySince = nil
        }
    }

    /// Sets the mute to `on`, whatever the connection is doing; asking again for the state it holds does nothing.
    /// Muted, nothing from the mic leaves the Mac until the user unmutes: not live speech, not speech kept for a
    /// session, and what the provider buffered is dropped. Unmuting a session that closed meanwhile (not one the user
    /// disconnected) reopens it: at once, or, gated, when you next speak.
    public func setMuted(_ on: Bool) {
        guard on != muted else { return }
        muted = on
        audio.setMuted(micIdle)
        if on {
            clearHeardInput()
            // The mic is off: a turn of yours still waiting for the sensor to hear you stop is over now.
            let ending = speechEndPending
            forgetSpeech()
            if ending { onSpeech?(false) }
            return note("🔇 muted")
        }
        if micOff { return note("🎙  unmuted (still \(paused ? "paused" : "disconnected"))") }
        if standby { return note("🎙  unmuted") } // between conversations: the next one hears you
        guard status == .disconnected else { return note("🎙  listening") }
        attempts = 0
        if gated {
            // No need to pay for a session before you say something.
            dormant = true
            return note("🎙  listening; the session opens when you speak")
        }
        note("🎙  listening")
        connect()
    }

    /// Whether the mic queue lets speech through, to the session or held for it. Closed while muted, paused or
    /// disconnected by the user.
    public var micOpen: Bool { micShared.withLock { !$0.muted } }

    /// Stops the assistant mid-sentence (Esc or a spoken "stop"): cancels generation and drops queued audio.
    public func stopSpeech(reason: String) {
        guard responseActive || audio.isSpeaking else { return }
        if responseActive { send(.cancelReply) }
        replies.reset()
        awaitingCreated = false
        droppingAudio = true
        cutPlayback()
        note("⏹  stopped (\(reason))")
    }

    // Session controls. Pause holds everything but keeps the connection (the quiet close still applies); a
    // disconnect closes it and keeps it closed. The two are independent of mute and of each other.

    /// Holds everything: the mic goes off, whatever is being said stops at once, and replies (`requestResponse`)
    /// and agent reports (`deliver`) wait for `resume()`.
    public func pause() {
        guard !paused else { return }
        paused = true
        audio.setMuted(micIdle)
        stopSpeech(reason: "paused")
        if status == .live { clearHeardInput() }
        awaitingReplySince = nil
        note("⏸  paused; the mic is off and replies wait until you resume")
    }

    /// Ends a pause: the mic comes back (unless muted), and what waited is said, reopening a closed session for it.
    public func resume() {
        guard paused else { return }
        paused = false
        audio.setMuted(micIdle)
        note(outbox.isEmpty ? "▶  resumed" : "▶  resumed; delivering what came in while paused")
        if status == .live && established {
            flushOutbox()
            if replies.resume() { requestResponse() } // a reply held back while paused
        } else if status == .disconnected, !outbox.isEmpty, !disconnectedByUser, !retryPending {
            attempts = 0
            connect()
        }
    }

    /// Closes the session now, so its billing stops, and keeps it closed: speech, agent reports and retries don't
    /// reopen it (`connect`, `wake`, `deliver`, `scheduleRetry`), only `reconnect()` or a typed message. Reports
    /// that arrive meanwhile wait in the outbox for the next session.
    public func disconnect() {
        guard !disconnectedByUser else { return }
        disconnectedByUser = true
        connection += 1 // a scheduled retry, or a tool result, belongs to the session being closed
        retryPending = false
        renewWhenIdle = false
        dormant = false
        if let s = socket {
            socket = nil // its close must not count as a failure
            s.close(.normalClosure)
        }
        keepalive?.cancel()
        keepalive = nil
        if audio.isSpeaking { _ = audio.interrupt() } // the voice stops with its session
        droppingAudio = false
        status = .disconnected
        replies.reset()
        awaitingCreated = false
        awaitingReplySince = nil
        audio.setMuted(micIdle)
        submitWhenUp = false
        micShared.withLock {
            $0.midTurn = false
            $0.held.reset() // speech from before the disconnect isn't replayed into the next session
        }
        note("⏏  disconnected; stays closed until you connect or type")
    }

    /// Opens the session now: after `disconnect()`, or instead of waiting for speech (closed while quiet) or for a
    /// scheduled retry. Reports held meanwhile are delivered once it's up.
    public func reconnect() {
        disconnectedByUser = false
        audio.setMuted(micIdle)
        guard status == .disconnected else { return }
        attempts = 0
        guard !providerPreparing else { return note("… connects once \(provider.menuTitle) is ready") }
        connect()
    }

    // Conversations on request (the companion's tap-to-talk and wake word). Between them the mic is on standby and
    // the session closed, so nothing is billed; a tap opens one, the session decides when each turn is over
    // (`deferReplies`, `submitTurn`), and `rest` ends it.

    /// Standby on or off (see `standby`). Turning it on drops speech held for a session.
    public func setStandby(_ on: Bool) {
        guard on != standby else { return }
        standby = on
        if audioStarted { audio.setMuted(micIdle) }
        if on { micShared.withLock { $0.held.reset() } }
    }

    /// The activation key went down and may be a tap: keep the mic's speech here, so none of it is lost, but connect
    /// nothing and stream nothing (a key-down may be the start of ⌘C, and a stray connect is billed). `listen` sends
    /// what was kept once the press turns out to be a tap; `rest` drops it.
    public func buffer() {
        guard !disconnectedByUser else { return }
        buffering = true
        setStandby(false)
    }

    /// Starts a conversation the user asked for (a tap, the wake word): the mic leaves standby and the session opens
    /// now if it's closed; speech meanwhile (and what `buffer` kept) is held and sent once it's up. An explicit
    /// request, like typing, so it also ends a disconnect.
    public func listen() {
        let wasBuffering = buffering
        buffering = false
        setStandby(false)
        if disconnectedByUser { return reconnect() }
        // Already up (her report reopened it): what was kept goes now, ahead of the live mic.
        if wasBuffering, status == .live, established { _ = activateHeldAudio() }
        openIfClosed()
    }

    private func openIfClosed() {
        guard status == .disconnected, !providerPreparing else { return }
        attempts = 0
        connect()
    }

    /// Ends a conversation: the mic goes back on standby, whatever is said stops, speech held or heard is dropped,
    /// and the session closes like a quiet one, so billing stops (an agent report still reopens it). `quietly` keeps
    /// it out of the UI (a cancelled key press is not news).
    public func rest(_ why: String, quietly: Bool = false) {
        buffering = false
        setStandby(true)
        submitWhenUp = false
        if responseActive || audio.isSpeaking { stopSpeech(reason: why) }
        connection += 1 // a scheduled retry, or a tool result, belongs to the conversation being closed
        retryPending = false
        guard status != .disconnected else { return }
        clearHeardInput()
        goDormant(why, until: "you talk to her again", quietly: quietly)
    }

    /// The user's spoken turn is over (deferred replies: the companion's cooldown ran out): the reply is asked for.
    /// Before the session is up it waits, and goes right after the speech held meanwhile. Elsewhere the provider has
    /// already answered the turn by itself.
    public func submitTurn() {
        guard deferring, !micOff else { return }
        guard status == .live, established else {
            submitWhenUp = true
            return
        }
        awaitingReplySince = Date()
        if replies.wantReply() { requestResponse() }
    }

    /// Something is being worked on or said for the user's turn: a reply generating or audible, a tool running, or a
    /// reply awaited. Unlike `thinking`, agents busy in the background don't count.
    public var replying: Bool {
        let awaiting = awaitingReplySince.map { Date().timeIntervalSince($0) < Activity.replyTimeout } ?? false
        return responseActive || audio.isSpeaking || toolsRunning > 0 || awaiting
    }

    private func enforce(_ verdict: SpeechPolicy.Verdict) {
        switch verdict {
        case .ok:
            break
        case .tooLong:
            // Stop generating; what was already heard or queued plays out, the rest is dropped.
            if responseActive { send(.cancelReply) }
            replies.reset()
            awaitingCreated = false
            droppingAudio = true
            note("✂  cut after \(Int(SpeechPolicy.maxAudioSeconds)) s of speech")
        case .leak(let what):
            // Cutting here would land mid-word, seconds before the audio catches up with the transcript. Let the
            // reply finish (the audio cap still bounds it) and correct the model afterwards.
            leaked = what
            note("⚠  the voice read \(what) aloud; it will be told not to")
        }
    }

    /// After a reply that read code-like text aloud: tell the model, without asking for another reply.
    private func correctLeak() {
        guard let what = leaked else { return }
        leaked = nil
        guard !correctedLeak else { return }
        correctedLeak = true
        send(.userText("[policy] Your last reply read \(what) aloud. Never say code, paths, file names, URLs or diffs; "
            + "describe them in plain words. Don't answer this note.", expectsReply: false))
    }

    /// The mic's speech sensor heard you start (true) or stop (false) talking. A start confirms the provider's "speech
    /// started" from up to `bargeInWindow` before it; a stop ends the turn the provider already took for over.
    private func micHeardSpeech(_ speaking: Bool) {
        micHearsSpeech = speaking
        if speaking {
            if let pending = providerSpeech, !pending.counted,
               Date().timeIntervalSince(pending.since) < Self.bargeInWindow {
                confirmSpeech()
            }
        } else if speechEndPending {
            speechEndPending = false
            onSpeech?(false)
        }
    }

    /// The provider heard speech start and the mic's speech sensor agrees: it's you. Talking over her stops her
    /// (barge-in; the provider's VAD stops what it was generating), and the companion hears your turn begin.
    private func confirmSpeech() {
        guard let pending = providerSpeech, !pending.counted else { return }
        providerSpeech = (since: pending.since, counted: true)
        cutPlayback()
        onSpeech?(true)
    }

    /// Forgets a turn of yours in progress (a new connection, the mic going off): nothing is left to confirm or end.
    private func forgetSpeech() {
        providerSpeech = nil
        micHearsSpeech = false
        speechEndPending = false
    }

    /// Stops local playback and tells the server how much of the reply was actually heard.
    private func cutPlayback() {
        guard let cut = audio.interrupt() else { return }
        send(.truncate(itemID: cut.item, audioEndMs: cut.heardMs))
    }

    private func receive(_ task: any SessionSocket) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, task === self.socket else { return }
                switch result {
                case .success(let message):
                    let text: String? = switch message {
                    case .string(let t): t
                    case .data(let d): WireFrame.text(d) // Gemini sends its JSON as binary frames
                    @unknown default: nil
                    }
                    if let text {
                        let events = self.wire.decode(text)
                        if self.debugEvents { self.logEvents(events) }
                        if !self.established,
                           !self.capabilities.setupHandshake || events.contains(.sessionReady) {
                            self.sessionEstablished()
                        }
                        events.forEach(self.handle)
                    }
                    self.receive(task)
                case .failure(let err):
                    let reason = self.closeReason ?? .dropped
                    // Some providers (Gemini) explain a refused or closed connection in the close frame.
                    let said = task.closeReason.map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 }
                    self.connectionLost(task, reason: reason,
                                        detail: reason == .sessionEnded ? "provider ended the session (idle or time limit)"
                                                                      : "disconnected: \(said ?? err.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .sessionReady:
            break
        case .audioDelta(let item, let b64):
            // Paused: nothing is voiced, even from a reply whose cancel crossed a response.created that reset
            // droppingAudio.
            if paused { return }
            if !droppingAudio { enforce(policy.audio(base64Count: b64.utf8.count)) }
            if !droppingAudio { audio.play(base64: b64, item: item) }
        case .responseCreated:
            replies.responseCreated()
            awaitingCreated = false
            micShared.withLock { $0.midTurn = false }
            awaitingReplySince = nil
            droppingAudio = false
            // A run_shell approval question reads the command aloud on purpose.
            policy = SpeechPolicy(allowCode: ConfirmGate.shared.pendingAction?.hasPrefix("run_shell") == true)
        case .assistantTranscriptDelta(let delta):
            enforce(policy.feed(delta))
        case .assistantTranscript(let t):
            log("voice: \(t)")
            recap.add("voice", t)
            onEvent?(.voice(t))
        case .assistantTranscriptItem(let itemID, let t):
            log("voice: \(t)")
            recap.add("voice", t, itemID: itemID)
            onEvent?(.voice(t))
        case .assistantTranscriptTruncated(let itemID, let t):
            recap.replace(itemID: itemID, speaker: "voice", with: t)
        case .userTranscript(let t):
            let said = t.trimmingCharacters(in: .whitespacesAndNewlines)
            log("you:   \(said)")
            recap.add("you", t)
            onEvent?(.you(said))
            if !said.isEmpty { onUserTurn?(said) }
            if speechOverlappedPlayback {
                note("… you spoke over the voice; that can't confirm anything (it may be its own echo). Say it again.")
            } else {
                ConfirmGate.shared.heard(t)
            }
            speechOverlappedPlayback = false
            correctedLeak = false
            // The server may already be answering the "stop" itself; cancel that too.
            if StopCommand.matches(t) {
                stopSpeech(reason: "you said stop")
            } else if capabilities.explicitSpeechOnsets, replies.wantReply() {
                requestResponse() // no server VAD to answer a finished utterance by itself
            }
        case .speechStopped:
            if !muted && !deferring { awaitingReplySince = Date() } // deferred: from submitTurn
            micShared.withLock { $0.midTurn = false }
            let counted = providerSpeech?.counted ?? false
            if providerSpeech != nil, !counted, audio.isSpeaking {
                note("… kept talking: the mic heard no speech (echo or noise)")
            }
            providerSpeech = nil
            guard counted else { return } // noise or her echo: no turn of yours began, so none ends
            // Your turn is over once the mic hears you stop too (a pause the provider took for the end isn't).
            if micHearsSpeech && !capabilities.explicitSpeechOnsets {
                speechEndPending = true
            } else {
                onSpeech?(false)
            }
        case .speechStarted:
            speechOverlappedPlayback = audio.isSpeaking // before barge-in stops the playback below
            lastSpeechStart = Date()
            micShared.withLock { $0.midTurn = true }
            awaitingReplySince = nil
            if capabilities.turnEpochs {
                // Every onset starts a new epoch and the provider cancels everything older, heard or not, so
                // no response.created/done or reply from before it will arrive; waiting on one would stall replies.
                if responseActive { send(.cancelReply) }
                replies.reset()
                awaitingCreated = false
                droppingAudio = audio.isSpeaking
            }
            speechEndPending = false
            providerSpeech = (since: Date(), counted: false)
            // The session's own gate marked it (explicit onsets), or every sound is streamed: nothing to confirm.
            if capabilities.explicitSpeechOnsets || !gated || micHearsSpeech { confirmSpeech() }
        case .functionCall(let callID, let name, let args):
            runTool(callID: callID, name: name, args: args, epoch: nil)
        case .localFunctionCall(let epoch, let callID, let name, let args):
            runTool(callID: callID, name: name, args: args, epoch: epoch)
        case .error(let msg):
            if capabilities.setupHandshake, !established {
                // The setup was refused (a protocol or tool-manifest mismatch): the same setup would be refused
                // again, so stay closed until the provider is prepared afresh (for Local, its helper relaunched).
                note("✖ \(provider.menuTitle) handshake failed: \(msg)")
                let failed = socket
                socket = nil
                failed?.close(.protocolError)
                keepalive?.cancel()
                keepalive = nil
                status = .disconnected
                providerPreparing = true
                replies.reset()
                awaitingCreated = false
                awaitingReplySince = nil
                return
            }
            // A provider ending the session (idle, time limit) is routine: note it and let the close renew it.
            if Reconnect.isSessionEnd(msg) { closeReason = .sessionEnded } else { note("✖ \(msg)") }
            // A refused response.create would otherwise leave the scheduler waiting forever.
            if awaitingCreated {
                awaitingCreated = false
                if replies.responseDone() { requestResponse() }
            }
        case .responseDone:
            awaitingReplySince = nil
            correctLeak()
            // Tool results from this turn are answered together, in one reply, once it's finished.
            if replies.responseDone() { requestResponse() }
            if renewWhenIdle && !replies.responseActive && replies.callsInFlight == 0 { renewConnection() }
        case .resumptionHandle(let handle):
            resumeHandle = handle
        case .sessionEnding:
            // Gemini closes connections after about 10 minutes and warns first. Renew now (resuming the session
            // with its context), or right after whatever is being said or run finishes.
            if responseActive || audio.isSpeaking || replies.callsInFlight > 0 {
                renewWhenIdle = true
            } else {
                renewConnection()
            }
        case .ignored:
            break
        }
    }

    /// Switches to another provider from the orb's menu: the current session closes cleanly (its billing stops),
    /// the new one opens at once and gets the recap, so the conversation carries over. Tool results meant for the
    /// old session are dropped (its calls can't be answered elsewhere); agent reports still arrive in the new one.
    @discardableResult
    public func beginProviderSwitch(to newProvider: Provider, voice newVoice: String) -> Bool {
        if newProvider == provider {
            // Picking Local again while it's down relaunches its helper process (a helper matter, not a protocol one).
            guard provider == .local, status == .disconnected else { return false }
            connection += 1 // invalidate a retry aimed at the old sidecar port
            retryPending = false
            providerPreparing = true
            requestOverride = nil
            return true
        }
        note("⇄ switching to \(newProvider.menuTitle) (voice \(newVoice))")
        if let old = socket {
            socket = nil // its close must not count as a failure
            old.close(.normalClosure)
        }
        keepalive?.cancel()
        keepalive = nil
        _ = audio.interrupt() // stop the old provider's voice mid-sentence
        droppingAudio = false
        status = .disconnected
        replies.reset()
        awaitingCreated = false
        provider = newProvider
        providerPreparing = true
        key = ""
        voice = newVoice
        requestOverride = nil
        let onsets = capabilities.explicitSpeechOnsets // already the new provider's
        micShared.withLock {
            $0.onsets = onsets
            $0.midTurn = false
            $0.wire = nil
            $0.socket = nil
            $0.held.reset()
        }
        resumeHandle = nil // resumption handles only mean something to the provider that issued them
        attempts = 0
        dormant = false
        greetNext = true
        return true
    }

    public func completeProviderSwitch(key newKey: String, request: URLRequest? = nil) {
        providerPreparing = false
        connectionLost = false
        key = newKey
        requestOverride = request
        connect()
    }

    public func switchProvider(to newProvider: Provider, key newKey: String, voice newVoice: String,
                        request: URLRequest? = nil) {
        guard newProvider != provider else { return }
        guard beginProviderSwitch(to: newProvider, voice: newVoice) else { return }
        completeProviderSwitch(key: newKey, request: request)
    }

    /// Replaces the connection before the provider drops it, resuming the same session where supported.
    private func renewConnection() {
        renewWhenIdle = false
        guard status == .live, let old = socket else { return }
        note(renewFresh ? "↻ renewing the connection with the new setup"
             : "↻ renewing the connection (the provider limits how long one lasts)")
        socket = nil // its close must not count as a failure
        old.close(.normalClosure)
        keepalive?.cancel()
        keepalive = nil
        status = .disconnected
        replies.reset()
        awaitingCreated = false
        connect()
    }

    private func requestResponse() {
        // Paused: the reply stays wanted and goes out on resume(). Gemini's pending outputs and texts wait with it.
        if paused { return replies.withhold() }
        if wire.capabilities.explicitReplies {
            awaitingCreated = true
            send(.requestReply)
            return
        }
        // Gemini answers by itself once it gets what it's waiting for: all the tool results of the turn, and/or a
        // completed text turn. Sending them now is the reply request.
        var sent = false
        if !pendingOutputs.isEmpty {
            send(.toolOutputs(pendingOutputs))
            pendingOutputs.removeAll()
            sent = true
        }
        if !pendingTexts.isEmpty {
            send(.userText(pendingTexts.joined(separator: "\n\n"), expectsReply: true))
            pendingTexts.removeAll()
            sent = true
        }
        // Nothing went out, so no reply will start: release the scheduler rather than wait forever.
        if !sent { _ = replies.responseDone() }
    }

    /// Text that should get a spoken reply: sent now where replies are requested separately, otherwise held until
    /// the scheduler allows a reply (sending a completed turn is what makes Gemini answer).
    private func addReplyText(_ text: String) {
        if wire.capabilities.explicitReplies {
            send(.userText(text, expectsReply: true))
        } else {
            pendingTexts.append(text)
        }
    }

    /// A tool call's result: sent at once where replies are requested separately (as before the wire layer),
    /// otherwise collected so every result of the turn goes back in one tool response.
    private func addToolOutput(_ output: ToolOutput) {
        if wire.capabilities.explicitReplies {
            send(.toolOutputs([output]))
        } else {
            pendingOutputs.append(output)
        }
    }

    private func runTool(callID: String, name: String, args: String, epoch: Int?) {
        if let epoch, !wire.isCurrent(epoch: epoch) {
            addToolOutput(ToolOutput(callID: callID, name: name,
                                     output: "Cancelled because a newer microphone turn began.", epoch: epoch))
            return
        }
        guard deduper.admit(name: name, arguments: args) else {
            note("⤫ \(name) repeated within seconds; not run again")
            addToolOutput(ToolOutput(callID: callID, name: name,
                                     output: "Duplicate of a call made moments ago; it was not run again. Don't repeat calls.",
                                     epoch: epoch))
            replies.callStarted()
            if replies.callFinished() { requestResponse() }
            return
        }
        replies.callStarted()
        log("→ \(name) \(args)")
        if name == "run_shell", let cmd = Self.field(args, "command") {
            log("   $ \(cmd)")   // the exact command the developer is being asked to approve
        }
        onEvent?(.toolCall(name: name, arguments: args))
        // Speech start comes from the mic via server VAD, so an injected report can't fake it.
        let userInitiated = lastSpeechStart > lastReport
        toolsRunning += 1
        let id = connection
        let host = host
        DispatchQueue.global().async {
            let outcome = host.call(name, arguments: args, userInitiated: userInitiated)
            DispatchQueue.main.async {
                self.toolsRunning -= 1
                self.onEvent?(.toolResult(name: name, output: outcome.output))
                if let target = outcome.watch { self.watch(target) }
                if let pane = outcome.paneWatch { self.watchPane(pane) }
                // A result for a call from a session that has since closed has nowhere to go.
                guard self.connection == id, self.status == .live else { return }
                self.addToolOutput(ToolOutput(callID: callID, name: name, output: outcome.output, epoch: epoch))
                // An epoch's old call may replace its history placeholder, but it cannot schedule a reply in a newer turn.
                if let epoch, !self.wire.isCurrent(epoch: epoch) { return }
                // One reply once every call from this turn has answered, not one per call.
                if self.replies.callFinished() { self.requestResponse() }
            }
        }
    }

    private func watch(_ target: String) {
        guard busyAgents.insert(target).inserted else { return }
        host.settle(target) { report in
            DispatchQueue.main.async {
                self.busyAgents.remove(target)
                self.note("← \(target) settled")
                self.lastReport = Date()
                self.deliver("[herdr] " + report)
            }
        }
    }

    private func watchPane(_ w: HerdrTools.PaneWatch) {
        let key = w.pane + "\u{0}" + w.regex
        guard watchedPanes.insert(key).inserted else { return }
        note("👁  watching \(w.label) for \(w.awaited)")
        host.watchPane(w) { report in
            DispatchQueue.main.async {
                self.watchedPanes.remove(key)
                self.note("← \(w.label) watch ended")
                self.lastReport = Date()
                self.deliver("[herdr] " + report)
            }
        }
    }

    private static func field(_ json: String, _ key: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?[key] as? String
    }

    /// HERDR_VOICE_DEBUG_EVENTS=1: log every provider event except audio, to diagnose a provider.
    private let debugEvents = ProcessInfo.processInfo.environment["HERDR_VOICE_DEBUG_EVENTS"] == "1"
    private func logEvents(_ events: [ServerEvent]) {
        for e in events {
            if case .audioDelta = e { continue }
            // A resumption handle can reopen the session for 2 hours: never print it.
            if case .resumptionHandle = e { log("·  resumptionHandle(<masked>)"); continue }
            log("·  \(e)".prefix(160).description)
        }
    }

    private func send(_ command: WireCommand) {
        wire.encode(command).forEach(sendRaw)
    }

    private func sendRaw(_ obj: [String: Any]) {
        guard let socket else { return }
        transmit([obj], on: socket, connection: connection)
    }

    /// Sends frames on `socket`, which belongs to `connection`. Nonisolated so the mic queue can stream with the
    /// socket it read under `micShared`.
    private nonisolated func transmit(_ frames: [[String: Any]], on socket: any SessionSocket, connection id: Int) {
        for obj in frames {
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { continue }
            socket.send(text: String(decoding: data, as: UTF8.self)) { [weak self] err in
                guard let err else { return }
                DispatchQueue.main.async {
                    // Failures on a socket that never came up, or has since been replaced, are already reported by
                    // the reconnect logic; only a live session's send errors are news.
                    guard let self, self.connection == id, self.established else { return }
                    self.note("✖ send: \(err.localizedDescription)")
                }
            }
        }
    }
}

public func log(_ line: String) {
    print(line)
    fflush(stdout)
}
