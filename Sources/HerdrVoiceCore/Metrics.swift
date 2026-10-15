import Foundation

/// One day's numbers, the small local aggregate the cockpit's widgets read (instant, offline). Phoenix holds the
/// per-turn detail; this keeps only sums.
public struct DayMetrics: Codable, Equatable, Sendable {
    /// USD by provider (`grok`, `openai`, ...).
    public var cost: [String: Double] = [:]
    /// Providers whose cost that day is an estimate.
    public var estimated: [String] = []
    public var connectedSeconds: [String: Double] = [:]
    public var tokens: [String: Int] = [:]
    /// Seconds of speech: the user's (as sent) and hers (as played).
    public var userTalkSeconds = 0.0
    public var voxTalkSeconds = 0.0
    public var conversations = 0
    public var turns = 0
    /// Tool calls she made.
    public var actions = 0
    /// Work handed to coding agents.
    public var delegations = 0
    public var approvalsAsked = 0
    public var approvalsGiven = 0
    public var interruptions = 0
    public var errors = 0
    /// Speech end to her first sound, summed over the turns that had both.
    public var latencyMsTotal = 0.0
    public var latencyCount = 0
    public var latencyMsMax = 0.0
    /// Herdr agents' working time, sampled while Vox runs.
    public var agentSeconds = 0.0
    /// The most Herdr agents seen working at once.
    public var agentsPeak = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case cost, estimated, connectedSeconds, tokens, userTalkSeconds, voxTalkSeconds, conversations, turns, actions
        case delegations, approvalsAsked, approvalsGiven, interruptions, errors, latencyMsTotal, latencyCount
        case latencyMsMax, agentSeconds, agentsPeak
    }

    /// Tolerant: a field a newer or older Vox didn't write reads as zero, so the file never resets.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        cost = value(.cost, [:])
        estimated = value(.estimated, [])
        connectedSeconds = value(.connectedSeconds, [:])
        tokens = value(.tokens, [:])
        userTalkSeconds = value(.userTalkSeconds, 0)
        voxTalkSeconds = value(.voxTalkSeconds, 0)
        conversations = value(.conversations, 0)
        turns = value(.turns, 0)
        actions = value(.actions, 0)
        delegations = value(.delegations, 0)
        approvalsAsked = value(.approvalsAsked, 0)
        approvalsGiven = value(.approvalsGiven, 0)
        interruptions = value(.interruptions, 0)
        errors = value(.errors, 0)
        latencyMsTotal = value(.latencyMsTotal, 0)
        latencyCount = value(.latencyCount, 0)
        latencyMsMax = value(.latencyMsMax, 0)
        agentSeconds = value(.agentSeconds, 0)
        agentsPeak = value(.agentsPeak, 0)
    }

    public var totalCost: Double { cost.values.reduce(0, +) }
    public var talkSeconds: Double { userTalkSeconds + voxTalkSeconds }
    public var averageLatencyMs: Double? { latencyCount > 0 ? latencyMsTotal / Double(latencyCount) : nil }
    public var costIsEstimated: Bool { !estimated.isEmpty }

    public mutating func addCost(_ usd: Double, provider: String, estimated isEstimate: Bool) {
        guard usd > 0 else { return }
        cost[provider, default: 0] += usd
        if isEstimate, !estimated.contains(provider) { estimated.append(provider) }
    }

    /// Folds one finished turn in (its cost by tokens; time-based cost is added as the connection runs).
    public mutating func add(_ turn: TurnRecord) {
        turns += 1
        actions += turn.tools.count
        delegations += turn.tools.filter(\.delegation).count
        approvalsAsked += turn.confirmationsAsked
        approvalsGiven += turn.confirmationsGiven
        interruptions += turn.interruptions
        errors += turn.errors
        if let usage = turn.usage { tokens[turn.provider, default: 0] += usage.totalTokens }
        if let latency = turn.latencyMs {
            latencyMsTotal += latency
            latencyCount += 1
            latencyMsMax = max(latencyMsMax, latency)
        }
    }
}

/// Every day kept, by `yyyy-MM-dd` in the user's time zone, with the price table its costs were priced with.
/// `~/.vox/metrics.json`; days older than `keepDays` are dropped.
public struct MetricsLedger: Codable, Equatable, Sendable {
    public static let keepDays = 90

    public var version = 1
    public var priceTable = PriceTable.current.version
    public var days: [String: DayMetrics] = [:]

    public init() {}

    public static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func day(_ date: Date, calendar: Calendar = .current) -> DayMetrics {
        days[Self.key(date, calendar: calendar)] ?? DayMetrics()
    }

    public mutating func update(_ date: Date, calendar: Calendar = .current, _ change: (inout DayMetrics) -> Void) {
        let key = Self.key(date, calendar: calendar)
        var day = days[key] ?? DayMetrics()
        change(&day)
        days[key] = day
    }

    /// The last `count` days ending with `date`, oldest first, empty days included.
    public func lastDays(_ count: Int, endingAt date: Date, calendar: Calendar = .current) -> [(date: Date, metrics: DayMetrics)] {
        let today = calendar.startOfDay(for: date)
        return (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { ($0, day($0, calendar: calendar)) }
        }
    }

    /// Drops the days older than `keepDays` before `date`.
    public mutating func trim(before date: Date, calendar: Calendar = .current) {
        guard let oldest = calendar.date(byAdding: .day, value: -Self.keepDays, to: calendar.startOfDay(for: date)) else { return }
        let cutoff = Self.key(oldest, calendar: calendar)
        days = days.filter { $0.key >= cutoff }
    }

    public static func load(_ url: URL) -> MetricsLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(MetricsLedger.self, from: data) else { return MetricsLedger() }
        return ledger
    }

    public func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
