import Foundation
import HerdrVoiceCore
import VoiceEngine

/// The day's numbers as they happen: talk time per side, connected time, cost by provider (priced with the versioned
/// `PriceTable`), and each finished turn (`TurnLedger`) folded into `~/.vox/metrics.json`. The cockpit reads the
/// published snapshot, which catches up every couple of seconds, not every frame. Finished turns also go to
/// `onTurn` (the Phoenix export).
@MainActor final class MetricsRecorder: ObservableObject {
    static let publishInterval: TimeInterval = 2
    static let saveInterval: TimeInterval = 15

    let url: URL
    let prices: PriceTable
    /// What the cockpit shows.
    @Published private(set) var snapshot: MetricsLedger
    var provider: Provider {
        willSet { if newValue != provider { endConnection(at: Date()) } }
        didSet { turns.provider = provider }
    }
    /// Each finished turn, for the Phoenix export.
    var onTurn: ((TurnRecord) -> Void)?
    /// Each stretch of connected time with its cost (at most `connectionSpan` long), for the Phoenix export.
    var onConnection: ((ConnectionRecord) -> Void)?
    static let connectionSpan: TimeInterval = 300

    private var ledger: MetricsLedger
    private var turns: TurnLedger
    private var lastFrame: Date?
    private var lastPublish = Date.distantPast
    private var lastSave = Date()
    private var dirty = false
    /// Typed turns, whose echo as the user's words isn't a second turn.
    private var typedEchoes: [String] = []
    /// The stretch of connected time not yet reported.
    private var connection: ConnectionRecord?
    private let io = DispatchQueue(label: "voice-companion.metrics", qos: .utility)

    init(url: URL, provider: Provider, prices: PriceTable = .current) {
        self.url = url
        self.prices = prices
        self.provider = provider
        let loaded = MetricsLedger.load(url)
        ledger = loaded
        snapshot = loaded
        turns = TurnLedger(provider: provider, prices: prices)
    }

    var today: DayMetrics { snapshot.day(Date()) }

    // MARK: what comes in

    func talk(_ side: VoiceClip.Side, seconds: Double, at now: Date = Date()) {
        update(now) { day in
            if side == .user {
                day.userTalkSeconds += seconds
            } else {
                day.voxTalkSeconds += seconds
                day.addCost(prices.cost(connectedSeconds: 0, spokenSeconds: seconds, provider: provider),
                            provider: provider.rawValue, estimated: prices.row(provider)?.estimated ?? false)
            }
        }
        if side == .vox, connection != nil {
            connection?.spokenSeconds += seconds
            connection?.costUSD += prices.cost(connectedSeconds: 0, spokenSeconds: seconds, provider: provider)
        }
    }

    /// Herdr agents' working time, sampled (see AgentsWatcher).
    func agentTime(_ seconds: Double, at now: Date = Date()) {
        update(now) { $0.agentSeconds += seconds }
    }

    /// How many Herdr agents were working at the last look (the day keeps the most at once).
    func agentsWorking(_ count: Int, at now: Date = Date()) {
        guard count > ledger.day(now).agentsPeak else { return }
        update(now) { $0.agentsPeak = count }
    }

    func conversationStarted(at now: Date = Date()) {
        update(now) { $0.conversations += 1 }
    }

    func usage(_ usage: RealtimeUsage, at now: Date = Date()) {
        turns.usage(usage)
        update(now) { $0.addCost(prices.cost(usage, provider: provider), provider: provider.rawValue, estimated: false) }
    }

    func speech(started: Bool, interrupting: Bool, at now: Date = Date()) {
        if started {
            if let closed = turns.speechStarted(at: now) { finished(closed) }
            if interrupting { turns.interrupted() }
        } else {
            turns.speechEnded(at: now)
        }
    }

    func submitted(at now: Date = Date()) { turns.submitted(at: now) }

    func typed(_ text: String, at now: Date = Date()) {
        typedEchoes.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let closed = turns.userText(text, typed: true, at: now) { finished(closed) }
    }

    func route(_ decision: RouteDecision, milliseconds: Double) {
        turns.route(TurnRecord.Route(skill: decision.skill, source: decision.source == .jev ? "jev" : "words",
                                     confidence: decision.confidence, milliseconds: milliseconds))
    }

    func replyAudio(at now: Date = Date()) { turns.replyAudio(at: now) }

    func interrupted() { turns.interrupted() }

    /// The session's events: the user's and her words (counted), tools, and errors.
    func heard(_ event: SessionEvent, at now: Date = Date()) {
        switch event {
        case .you(let text):
            if let echo = typedEchoes.firstIndex(of: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                typedEchoes.remove(at: echo)
            } else if let closed = turns.userText(text, typed: false, at: now) {
                finished(closed)
            }
        case .voice(let text): turns.voiceText(text)
        case .toolCall(let name, let arguments): turns.toolStarted(name, arguments: arguments, at: now)
        case .toolResult(let name, let output): turns.toolFinished(name, output: output, at: now)
        case .note(let text):
            guard text.hasPrefix("✖") else { return }
            if turns.open != nil { turns.error() } else { update(now) { $0.errors += 1 } }
        }
    }

    /// Each frame: connected time (and its cost, for a model billed by the minute), a turn that has settled, and
    /// the snapshot and the file catching up now and then.
    func frame(at now: Date, connected: Bool, busy: Bool) {
        let dt = lastFrame.map { min(max(now.timeIntervalSince($0), 0), 0.5) } ?? 0
        lastFrame = now
        if connected, dt > 0 {
            let cost = prices.cost(connectedSeconds: dt, spokenSeconds: 0, provider: provider)
            update(now, publish: false) { day in
                day.connectedSeconds[provider.rawValue, default: 0] += dt
                day.addCost(cost, provider: provider.rawValue, estimated: prices.row(provider)?.estimated ?? false)
            }
            if connection == nil {
                connection = ConnectionRecord(provider: provider.rawValue, model: provider.model,
                                              start: now.addingTimeInterval(-dt), end: now,
                                              estimated: prices.row(provider)?.estimated ?? false)
            }
            connection?.connectedSeconds += dt
            connection?.costUSD += cost
            connection?.end = now
            if let start = connection?.start, now.timeIntervalSince(start) >= Self.connectionSpan { endConnection(at: now) }
        } else if !connected {
            endConnection(at: now)
        }
        if let settled = turns.tick(at: now, busy: busy) { finished(settled) }
        if dirty, now.timeIntervalSince(lastPublish) >= Self.publishInterval { publish(now) }
        if dirty, now.timeIntervalSince(lastSave) >= Self.saveInterval { save(at: now) }
    }

    /// The session closed or the app quits: the open turn ends and everything is written.
    func flush(at now: Date = Date()) {
        if let closed = turns.finish(at: now) { finished(closed) }
        endConnection(at: now)
        publish(now)
        save(at: now)
    }

    // MARK: helpers

    /// Reports the connected stretch so far (a drop, a provider switch, five minutes, quitting).
    private func endConnection(at now: Date) {
        guard var stretch = connection else { return }
        connection = nil
        stretch.end = max(stretch.start, min(now, stretch.end.addingTimeInterval(1)))
        if stretch.connectedSeconds >= 1 { onConnection?(stretch) }
    }

    private func finished(_ turn: TurnRecord) {
        update(turn.end) { $0.add(turn) }
        onTurn?(turn)
    }

    private func update(_ date: Date, publish: Bool = true, _ change: (inout DayMetrics) -> Void) {
        ledger.update(date, change)
        dirty = true
        if publish, date.timeIntervalSince(lastPublish) >= Self.publishInterval { self.publish(date) }
    }

    private func publish(_ now: Date) {
        lastPublish = now
        if snapshot != ledger { snapshot = ledger }
    }

    private func save(at now: Date) {
        lastSave = now
        dirty = false
        ledger.trim(before: now)
        let ledger = ledger, url = url
        io.async { try? ledger.save(url) }
    }

    /// Replaces the numbers (the self-test and the phone's renders stage a week).
    func stage(_ staged: MetricsLedger) {
        ledger = staged
        snapshot = staged
    }

    func drain() { io.sync {} }
}
