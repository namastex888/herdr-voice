import Foundation

/// One voice turn, as metadata: when the user spoke and when she answered, how it was routed, what ran, what was
/// asked, what was cut off, what it used and cost. No words: the transcripts stay in the voice chat on this Mac.
public struct TurnRecord: Equatable, Sendable {
    public struct Route: Equatable, Sendable {
        public var skill: String
        /// `jev` or `words`.
        public var source: String
        public var confidence: Double
        public var milliseconds: Double

        public init(skill: String, source: String, confidence: Double, milliseconds: Double) {
            self.skill = skill
            self.source = source
            self.confidence = confidence
            self.milliseconds = milliseconds
        }
    }

    public struct Tool: Equatable, Sendable {
        public enum Outcome: String, Sendable { case ok, error, confirmation, running }
        public var name: String
        public var start: Date
        public var end: Date?
        public var outcome: Outcome
        /// Work handed to a coding agent (Herdr's `prompt_agent`, `start_agent`), and to which.
        public var delegation: Bool
        public var target: String?

        public init(name: String, start: Date, end: Date? = nil, outcome: Outcome, delegation: Bool = false,
                    target: String? = nil) {
            self.name = name
            self.start = start
            self.end = end
            self.outcome = outcome
            self.delegation = delegation
            self.target = target
        }
    }

    /// A stable id, also the trace id's source.
    public var id: String
    public var provider: String
    public var model: String
    public var start: Date
    /// When the user stopped speaking (or typed); then when the turn was handed over (after the cooldown).
    public var speechEnd: Date?
    public var submitted: Date?
    public var firstAudio: Date?
    public var end: Date
    public var typed = false
    public var route: Route?
    public var tools: [Tool] = []
    public var confirmationsAsked = 0
    public var confirmationsGiven = 0
    public var interruptions = 0
    public var usage: RealtimeUsage?
    public var costUSD = 0.0
    public var costEstimated = false
    public var errors = 0
    public var userWords = 0
    public var voiceWords = 0

    public init(id: String, provider: String, model: String, start: Date, end: Date) {
        self.id = id
        self.provider = provider
        self.model = model
        self.start = start
        self.end = end
    }

    /// From the end of the user's speech to her first sound.
    public var latencyMs: Double? {
        guard let firstAudio, let from = speechEnd ?? submitted else { return nil }
        return max(0, firstAudio.timeIntervalSince(from) * 1000)
    }

    /// The cooldown: speech end to the turn being handed over.
    public var cooldownMs: Double? {
        guard let speechEnd, let submitted, submitted >= speechEnd else { return nil }
        return submitted.timeIntervalSince(speechEnd) * 1000
    }

    /// The model's own time: hand-over to her first sound.
    public var modelMs: Double? {
        guard let firstAudio, let from = submitted ?? speechEnd else { return nil }
        return max(0, firstAudio.timeIntervalSince(from) * 1000)
    }

    public var toolMs: Double {
        tools.reduce(0) { $0 + (($1.end ?? $1.start).timeIntervalSince($1.start) * 1000) }
    }
}

/// Builds `TurnRecord`s from the session's events as they happen. A turn opens with the user's speech (or a typed
/// message), collects routing, tools, questions, her audio and usage, and closes once she has been idle for
/// `settle` seconds after doing something, or when the user starts the next turn.
public struct TurnLedger: Sendable {
    public static let settle: TimeInterval = 1.5
    /// Tools that hand work to a coding agent.
    public static let delegationTools: Set<String> = ["prompt_agent", "start_agent"]

    public private(set) var open: TurnRecord?
    /// Tools whose question waits for a yes.
    private var askedTools: Set<String> = []
    private var idleSince: Date?
    public var provider: Provider
    public var prices: PriceTable

    public init(provider: Provider, prices: PriceTable = .current) {
        self.provider = provider
        self.prices = prices
    }

    // MARK: events (each returns the turn it closed, if any)

    public mutating func speechStarted(at time: Date) -> TurnRecord? {
        // More speech before she did anything: the same turn (a pause, the cooldown resumed).
        if let open, !Self.answered(open) { return nil }
        let closed = close(at: time)
        begin(at: time)
        return closed
    }

    public mutating func speechEnded(at time: Date) {
        if open == nil { begin(at: time) }
        open?.speechEnd = time
    }

    public mutating func submitted(at time: Date) {
        if open == nil { begin(at: time) }
        open?.submitted = time
    }

    /// The user's words (counted, not kept). A typed turn opens and ends at once.
    public mutating func userText(_ text: String, typed: Bool, at time: Date) -> TurnRecord? {
        var closed: TurnRecord?
        if typed {
            closed = close(at: time)
            begin(at: time)
            open?.typed = true
            open?.speechEnd = time
            open?.submitted = time
        } else if open == nil {
            begin(at: time) // a transcript without speech events
        }
        open?.userWords += Self.words(text)
        return closed
    }

    public mutating func route(_ decision: TurnRecord.Route) {
        open?.route = decision
    }

    public mutating func toolStarted(_ name: String, arguments: String, at time: Date) {
        if open == nil { begin(at: time) }
        let delegation = Self.delegationTools.contains(name)
        let target = delegation ? Self.target(in: arguments) : nil
        open?.tools.append(TurnRecord.Tool(name: name, start: time, end: nil, outcome: .running, delegation: delegation,
                                           target: target))
        idleSince = nil
    }

    public mutating func toolFinished(_ name: String, output: String, at time: Date) {
        guard var turn = open else { return }
        let index = turn.tools.lastIndex { $0.name == name && $0.end == nil }
        let outcome: TurnRecord.Tool.Outcome = output.hasPrefix("CONFIRMATION REQUIRED") ? .confirmation
            : output.hasPrefix("error") || output.hasPrefix("✖") ? .error : .ok
        if let index {
            turn.tools[index].end = time
            turn.tools[index].outcome = outcome
        }
        switch outcome {
        case .confirmation:
            turn.confirmationsAsked += 1
            askedTools.insert(name)
        case .ok where askedTools.contains(name):
            turn.confirmationsGiven += 1
            askedTools.remove(name)
        case .error:
            turn.errors += 1
        default:
            break
        }
        open = turn
    }

    public mutating func replyAudio(at time: Date) {
        if open == nil { begin(at: time) }
        if open?.firstAudio == nil { open?.firstAudio = time }
        idleSince = nil
    }

    public mutating func voiceText(_ text: String) {
        open?.voiceWords += Self.words(text)
    }

    public mutating func interrupted() {
        open?.interruptions += 1
    }

    public mutating func usage(_ usage: RealtimeUsage) {
        guard var turn = open else { return }
        turn.usage = (turn.usage ?? RealtimeUsage()) + usage
        turn.costUSD += prices.cost(usage, provider: provider)
        open = turn
    }

    public mutating func error() {
        open?.errors += 1
    }

    /// Each frame: whether she's still on it (speaking, replying, a tool running). Returns the turn once settled.
    public mutating func tick(at now: Date, busy: Bool) -> TurnRecord? {
        guard let turn = open, Self.answered(turn) else { return nil }
        if busy || turn.tools.contains(where: { $0.end == nil }) {
            idleSince = nil
            return nil
        }
        let since = idleSince ?? now
        idleSince = since
        guard now.timeIntervalSince(since) >= Self.settle else { return nil }
        return close(at: since)
    }

    /// The session closed: whatever is open ends now.
    public mutating func finish(at time: Date) -> TurnRecord? { close(at: time) }

    // MARK: helpers

    private mutating func begin(at time: Date) {
        open = TurnRecord(id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                          provider: provider.rawValue, model: provider.model, start: time, end: time)
        idleSince = nil
    }

    private mutating func close(at time: Date) -> TurnRecord? {
        guard var turn = open else { return nil }
        open = nil
        idleSince = nil
        turn.end = max(time, turn.start)
        // By the minute: the turn's share of the connection, an estimate.
        if case .minutes? = prices.row(provider)?.basis {
            let seconds = turn.end.timeIntervalSince(turn.start)
            turn.costUSD += prices.cost(connectedSeconds: seconds, spokenSeconds: 0, provider: provider)
            turn.costEstimated = true
        }
        if prices.row(provider)?.estimated == true { turn.costEstimated = true }
        return turn
    }

    /// She has done something for it: spoken, run a tool, or used tokens.
    static func answered(_ turn: TurnRecord) -> Bool {
        turn.firstAudio != nil || !turn.tools.isEmpty || turn.usage != nil || turn.voiceWords > 0
    }

    static func words(_ text: String) -> Int { text.split { $0.isWhitespace }.count }

    /// The agent a delegation goes to, never the instruction's text.
    static func target(in arguments: String) -> String? {
        guard let args = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { return nil }
        for key in ["target", "agent", "name", "pane"] {
            if let value = args[key] as? String, !value.isEmpty { return String(value.prefix(80)) }
        }
        return nil
    }
}
