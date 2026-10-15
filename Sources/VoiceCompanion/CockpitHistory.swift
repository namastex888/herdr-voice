import Foundation
import HerdrVoiceCore

/// Where a detail chart's days come from. Phoenix, when it answers, is the source of truth for what Vox exported:
/// turns, cost, latency, actions, approvals, errors. Talk time, conversations and agent time aren't in the spans, so
/// they always come from the local aggregate (`~/.vox/metrics.json`), which is also the whole answer while Phoenix is
/// off or unreachable.
@MainActor final class CockpitHistory: ObservableObject {
    static let days = 14
    nonisolated static let maxPages = 10
    /// How long a fetch stays fresh.
    static let freshFor: TimeInterval = 60

    /// Phoenix's days by key, or nil while it hasn't answered.
    @Published private(set) var phoenix: [String: DayMetrics]?
    /// Why the local numbers are shown, when Phoenix didn't answer.
    @Published private(set) var problem = ""
    var config: () -> PhoenixConfig = { PhoenixConfig() }
    var apiKey: @Sendable () -> String? = { nil }
    private var fetched: Date?
    private var fetching = false

    /// The days to chart, oldest first, and where they come from in words.
    func days(for local: [(date: Date, metrics: DayMetrics)]) -> (days: [(date: Date, metrics: DayMetrics)], label: String) {
        guard let phoenix else {
            return (local, "From this Mac (~/.vox/metrics.json)" + (problem.isEmpty ? "." : "; \(problem)."))
        }
        let merged = local.map { day -> (date: Date, metrics: DayMetrics) in
            guard let traced = phoenix[MetricsLedger.key(day.date)] else { return day }
            var metrics = day.metrics
            metrics.cost = traced.cost
            metrics.estimated = traced.estimated
            metrics.turns = traced.turns
            metrics.actions = traced.actions
            metrics.approvalsAsked = traced.approvalsAsked
            metrics.approvalsGiven = traced.approvalsGiven
            metrics.interruptions = traced.interruptions
            metrics.errors = traced.errors
            metrics.latencyMsTotal = traced.latencyMsTotal
            metrics.latencyCount = traced.latencyCount
            metrics.latencyMsMax = traced.latencyMsMax
            return (day.date, metrics)
        }
        return (merged, "From Phoenix (project \(config().project)) where it has the day; talk, conversations and "
                + "agent time from this Mac.")
    }

    /// Asks Phoenix for the last two weeks of turns and connected time, off the main thread, at most once a minute.
    func refresh(now: Date = Date()) {
        let config = config()
        guard config.enabled else {
            phoenix = nil
            problem = "sending to Phoenix is off"
            return
        }
        guard !fetching, fetched.map({ now.timeIntervalSince($0) > Self.freshFor }) ?? true else { return }
        fetching = true
        let apiKey = apiKey
        let since = Calendar.current.date(byAdding: .day, value: -Self.days, to: Calendar.current.startOfDay(for: now)) ?? now
        Task.detached(priority: .utility) {
            let result = await Self.fetch(config: config, apiKey: apiKey(), since: since)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.fetching = false
                self.fetched = Date()
                switch result {
                case .success(let days):
                    self.phoenix = days
                    self.problem = ""
                case .failure(let error):
                    self.phoenix = nil
                    self.problem = error.text
                }
            }
        }
    }

    /// The configuration changed: the next look asks again.
    func forget() {
        phoenix = nil
        fetched = nil
    }

    struct Failure: Error { let text: String }

    /// One session for every look, so repeated refreshes don't leave sessions behind.
    nonisolated static let session = URLSession(configuration: .ephemeral)

    /// Every turn and connection span since `since`, summed per day.
    nonisolated static func fetch(config: PhoenixConfig, apiKey: String?, since: Date) async -> Result<[String: DayMetrics], Failure> {
        var days: [String: DayMetrics] = [:], cursor: String?
        for name in ["turn", "connection"] {
            cursor = nil
            for _ in 0..<maxPages {
                guard let url = config.spansURL(name: name, since: since, cursor: cursor) else {
                    return .failure(Failure(text: "the Phoenix address isn't a URL"))
                }
                var request = URLRequest(url: url, timeoutInterval: 3)
                if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
                guard let (data, response) = try? await session.data(for: request) else {
                    return .failure(Failure(text: "Phoenix isn't answering"))
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 404 { break } // no project yet: nothing exported so far
                guard status == 200, let page = PhoenixHistory.days(fromPage: data) else {
                    return .failure(Failure(text: "Phoenix answered \(status)"))
                }
                for (key, day) in page.days { days[key] = merge(days[key], day) }
                guard let next = page.next else { break }
                cursor = next
            }
        }
        return .success(days)
    }

    nonisolated static func merge(_ a: DayMetrics?, _ b: DayMetrics) -> DayMetrics {
        guard var sum = a else { return b }
        for (provider, usd) in b.cost { sum.addCost(usd, provider: provider, estimated: b.estimated.contains(provider)) }
        for (provider, seconds) in b.connectedSeconds { sum.connectedSeconds[provider, default: 0] += seconds }
        sum.turns += b.turns
        sum.actions += b.actions
        sum.approvalsAsked += b.approvalsAsked
        sum.approvalsGiven += b.approvalsGiven
        sum.interruptions += b.interruptions
        sum.errors += b.errors
        sum.latencyMsTotal += b.latencyMsTotal
        sum.latencyCount += b.latencyCount
        sum.latencyMsMax = max(sum.latencyMsMax, b.latencyMsMax)
        return sum
    }
}
