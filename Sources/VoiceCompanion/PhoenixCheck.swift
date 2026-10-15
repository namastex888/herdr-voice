import Foundation
import HerdrVoiceCore

/// `VoiceCompanion --phoenix-check [ENDPOINT]`: sends one synthetic turn to Phoenix exactly as Vox exports a real one
/// (OTLP protobuf, project `vox`, the Keychain's PHOENIX_API_KEY if any), marked `vox.selftest` and with no words,
/// then reads it back through Phoenix's REST API. Exits 0 only when Phoenix returns the span. No microphone, no key.
@MainActor func runPhoenixCheck(endpoint: String?) -> Int32 {
    var config = PhoenixConfig()
    if let endpoint { config.endpoint = endpoint }
    let apiKey = Keychain.password(service: PhoenixConfig.keyService)
    print("Phoenix check: \(config.tracesURL?.absoluteString ?? config.endpoint), project \(config.project)"
          + (apiKey == nil ? "" : ", with PHOENIX_API_KEY"))

    let now = Date()
    let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var turn = TurnRecord(id: id, provider: "local", model: "self-test", start: now.addingTimeInterval(-3), end: now)
    turn.speechEnd = now.addingTimeInterval(-2.4)
    turn.submitted = now.addingTimeInterval(-1.9)
    turn.firstAudio = now.addingTimeInterval(-1.1)
    turn.route = TurnRecord.Route(skill: "chat", source: "words", confidence: 1, milliseconds: 3)
    turn.tools = [TurnRecord.Tool(name: "describe_self", start: now.addingTimeInterval(-1.8),
                                  end: now.addingTimeInterval(-1.6), outcome: .ok)]
    turn.voiceWords = 1
    var spans = TurnSpans.spans(turn, session: "self-test")
    spans[0].attributes.append((key: "vox.selftest", value: .bool(true)))

    let exporter = PhoenixExporter(config: config, apiKey: apiKey)
    exporter.export(spans)
    let sent = Waiter<PhoenixExporter.Outcome?>()
    exporter.flush { sent.finish($0) }
    guard let outcome = sent.wait(seconds: 10) ?? nil, outcome.ok else {
        print("✘ export failed: \(exporter.lastOutcome?.detail ?? "Phoenix didn't answer")")
        return 1
    }
    print("✔ exported \(outcome.spans) spans (turn, reply, tool) for trace \(id)")

    // Ingestion is asynchronous: read back for up to ten seconds.
    for attempt in 1...20 {
        if let span = findTurn(trace: id, config: config, apiKey: apiKey, since: now.addingTimeInterval(-120)) {
            let attributes = PhoenixHistory.flatten(span["attributes"] ?? [:])
            // Phoenix files openinference.span.kind as the span's own kind.
            let shown = ["vox.latency.total_ms", "vox.route.source", "vox.tools.count", "vox.cost.price_table"]
                .map { "\($0)=\(attributes[$0].map { "\($0)" } ?? "-")" }
            print("✔ Phoenix returned the turn span after \(attempt) look(s): kind=\(span["span_kind"] ?? "-"), "
                  + shown.joined(separator: ", "))
            // The detail charts' read: two weeks of turn and connection spans per day (the self-test span skipped).
            let history = Waiter<Result<[String: DayMetrics], CockpitHistory.Failure>>()
            let since = now.addingTimeInterval(-14 * 86_400)
            Task.detached { history.finish(await CockpitHistory.fetch(config: config, apiKey: apiKey, since: since)) }
            switch history.wait(seconds: 30) {
            case .success(let days)?:
                let turns = days.values.reduce(0) { $0 + $1.turns }
                print("✔ the detail charts can read Phoenix: \(days.count) day(s), \(turns) turn(s) of the user's")
                return 0
            case .failure(let failure)?:
                print("✘ reading history failed: \(failure.text)")
                return 1
            case nil:
                print("✘ reading history timed out")
                return 1
            }
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    print("✘ the span didn't show up in GET /v1/projects/\(config.project)/spans")
    return 1
}

/// The turn span with this trace id, from Phoenix's REST API.
private func findTurn(trace: String, config: PhoenixConfig, apiKey: String?, since: Date) -> [String: Any]? {
    guard let url = config.spansURL(name: "turn", since: since, limit: 100) else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 4)
    if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    let fetched = Waiter<Data?>()
    URLSession.shared.dataTask(with: request) { data, _, _ in fetched.finish(data) }.resume()
    guard let data = fetched.wait(seconds: 5) ?? nil,
          let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let spans = page["data"] as? [[String: Any]] else { return nil }
    return spans.first { ($0["context"] as? [String: Any])?["trace_id"] as? String == trace }
}

/// Waits for one value from another thread (the check runs before the app's run loop).
private final class Waiter<Value: Sendable>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: Value?

    func finish(_ value: Value) {
        lock.withLock { self.value = value }
        semaphore.signal()
    }

    func wait(seconds: Double) -> Value? {
        guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
        return lock.withLock { value }
    }
}
