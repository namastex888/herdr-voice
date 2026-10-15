import Foundation

/// Where Vox's spans go: the user's Phoenix (`settings.phoenix` in her configuration, the human's setting; the API
/// key, if any, in the Keychain as PHOENIX_API_KEY).
public struct PhoenixConfig: Equatable, Sendable {
    public static let defaultEndpoint = "http://127.0.0.1:6006"
    public static let defaultProject = "vox"
    public static let keyService = "PHOENIX_API_KEY"

    public var enabled = true
    /// Phoenix's base URL; `/v1/traces` and the REST API hang off it. A full `.../v1/traces` URL is accepted too.
    public var endpoint = PhoenixConfig.defaultEndpoint
    public var project = PhoenixConfig.defaultProject

    public init(enabled: Bool = true, endpoint: String = PhoenixConfig.defaultEndpoint,
                project: String = PhoenixConfig.defaultProject) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.project = project
    }

    public init(_ value: JSONValue?) {
        self.init()
        guard case .object(let object)? = value else { return }
        if let on = object["enabled"]?.bool { enabled = on }
        if let url = object["endpoint"]?.string?.trimmingCharacters(in: .whitespaces), !url.isEmpty { endpoint = url }
        if let name = object["project"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty { project = name }
    }

    public var json: JSONValue {
        .object(["enabled": .bool(enabled), "endpoint": .string(endpoint), "project": .string(project)])
    }

    /// The base URL, without a trailing `/v1/traces` or slash.
    public var base: URL? {
        var text = endpoint.trimmingCharacters(in: .whitespaces)
        for suffix in ["/v1/traces", "/"] where text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        guard let url = URL(string: text), url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    public var tracesURL: URL? { base?.appendingPathComponent("v1/traces") }

    /// `GET /v1/projects/<project>/spans` for one span name since a time (Phoenix's REST API).
    public func spansURL(name: String, since: Date, limit: Int = 1000, cursor: String? = nil) -> URL? {
        guard let base, var components = URLComponents(url: base.appendingPathComponent("v1/projects")
            .appendingPathComponent(project).appendingPathComponent("spans"), resolvingAgainstBaseURL: false)
        else { return nil }
        let formatter = ISO8601DateFormatter()
        components.queryItems = [URLQueryItem(name: "name", value: name),
                                 URLQueryItem(name: "start_time", value: formatter.string(from: since)),
                                 URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        return components.url
    }

    /// The request headers: protobuf, and the API key when there is one.
    public static func headers(apiKey: String?) -> [String: String] {
        var headers = ["Content-Type": "application/x-protobuf"]
        if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        return headers
    }
}

/// Sends spans to Phoenix in batches, on its own queue: the voice never waits for it. A batch that fails (Phoenix
/// down, refused) is dropped, not retried; the buffer is bounded, so a Phoenix that never answers costs nothing but
/// the attempts.
public final class PhoenixExporter: @unchecked Sendable { // all mutable state lives on `queue`
    public static let batchSize = 64
    public static let flushInterval: TimeInterval = 5
    public static let bufferLimit = 512

    /// What came of the last send, for Settings.
    public struct Outcome: Equatable, Sendable {
        public var time: Date
        public var spans: Int
        public var ok: Bool
        public var detail: String
    }

    private let queue = DispatchQueue(label: "vox.phoenix", qos: .utility)
    private let session: URLSession
    private var config: PhoenixConfig
    private var apiKey: String?
    private var buffer: [OTLPSpan] = []
    private var timer: DispatchSourceTimer?
    private var sending = false
    private var outcome: Outcome?
    private var dropped = 0
    public let version: String

    public init(config: PhoenixConfig, apiKey: String?, version: String = "0.4",
                session: URLSession = URLSession(configuration: .ephemeral)) {
        self.config = config
        self.apiKey = apiKey
        self.version = version
        self.session = session
    }

    public func configure(_ config: PhoenixConfig, apiKey: String?) {
        queue.async {
            self.config = config
            self.apiKey = apiKey
            if !config.enabled { self.buffer.removeAll() }
        }
    }

    /// Queues spans; returns at once.
    public func export(_ spans: [OTLPSpan]) {
        guard !spans.isEmpty else { return }
        queue.async {
            guard self.config.enabled else { return }
            self.buffer += spans
            if self.buffer.count > Self.bufferLimit {
                self.dropped += self.buffer.count - Self.bufferLimit
                self.buffer.removeFirst(self.buffer.count - Self.bufferLimit)
            }
            if self.buffer.count >= Self.batchSize { self.send() } else { self.armTimer() }
        }
    }

    /// Sends what's queued now (the self-test, quitting). `done` gets the outcome, on the exporter's queue.
    public func flush(_ done: (@Sendable (Outcome?) -> Void)? = nil) {
        queue.async { self.send(done) }
    }

    public var lastOutcome: Outcome? { queue.sync { outcome } }
    public var droppedSpans: Int { queue.sync { dropped } }
    public var queuedSpans: Int { queue.sync { buffer.count } }

    private func armTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.flushInterval)
        timer.setEventHandler { [weak self] in
            self?.timer = nil
            self?.send()
        }
        timer.resume()
        self.timer = timer
    }

    private func send(_ done: (@Sendable (Outcome?) -> Void)? = nil) {
        timer?.cancel()
        timer = nil
        guard !buffer.isEmpty, config.enabled, let url = config.tracesURL else {
            done?(nil)
            return
        }
        let batch = Array(buffer.prefix(Self.batchSize))
        buffer.removeFirst(batch.count)
        let body = OTLP.encode(batch, resource: [("service.name", .string("vox")),
                                                 ("service.version", .string(version)),
                                                 ("openinference.project.name", .string(config.project))],
                               scope: "vox", version: version)
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.httpBody = body
        for (field, value) in PhoenixConfig.headers(apiKey: apiKey) { request.setValue(value, forHTTPHeaderField: field) }
        session.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = error == nil && (200..<300).contains(status)
            let detail = ok ? "sent" : error.map { $0.localizedDescription } ?? "Phoenix answered \(status)"
            let result = Outcome(time: Date(), spans: batch.count, ok: ok, detail: detail)
            guard let self else {
                done?(result)
                return
            }
            self.queue.async {
                self.outcome = result
                if !ok { self.dropped += batch.count } // dropped, never retried: the voice comes first
                if !self.buffer.isEmpty { self.armTimer() }
                done?(result)
            }
        }.resume()
    }
}

/// Reads day-by-day history back from Phoenix's REST API: the turn spans Vox exported, summed per day into the same
/// shape as the local aggregate (cost, turns, actions, approvals, interruptions, errors, latency).
public enum PhoenixHistory {
    /// Spans' attributes, flattened to dotted keys whatever shape the API returns them in.
    public static func flatten(_ value: Any, prefix: String = "") -> [String: Any] {
        guard let dict = value as? [String: Any] else { return prefix.isEmpty ? [:] : [prefix: value] }
        var flat: [String: Any] = [:]
        for (key, inner) in dict {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if inner is [String: Any] {
                flat.merge(flatten(inner, prefix: path)) { a, _ in a }
            } else {
                flat[path] = inner
            }
        }
        return flat
    }

    /// One page of `GET /v1/projects/<project>/spans`: its turn spans summed per day key, and the next cursor.
    public static func days(fromPage data: Data, calendar: Calendar = .current) -> (days: [String: DayMetrics], next: String?)? {
        guard let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spans = page["data"] as? [[String: Any]] else { return nil }
        var days: [String: DayMetrics] = [:]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for span in spans {
            let name = span["name"] as? String
            guard name == "turn" || name == "connection", let started = span["start_time"] as? String,
                  let date = formatter.date(from: started) ?? plain.date(from: started) else { continue }
            let a = flatten(span["attributes"] ?? [:])
            if a["vox.selftest"] as? Bool == true { continue } // the self-test's own span isn't a turn of the user's
            func number(_ key: String) -> Double { (a[key] as? NSNumber)?.doubleValue ?? Double(a[key] as? String ?? "") ?? 0 }
            let key = MetricsLedger.key(date, calendar: calendar)
            var day = days[key] ?? DayMetrics()
            let provider = a["llm.provider"] as? String ?? "unknown"
            let estimated = a["vox.cost.estimated"] as? Bool ?? false
            // Minute-billed cost comes from the connection spans; a turn's own share of it would count it twice.
            if name == "connection" || a["vox.cost.basis"] as? String == "tokens" {
                day.addCost(number("vox.cost.usd"), provider: provider, estimated: estimated)
            }
            if name == "connection" {
                day.connectedSeconds[provider, default: 0] += number("vox.connected_seconds")
                days[key] = day
                continue
            }
            day.turns += 1
            day.actions += Int(number("vox.tools.count"))
            day.approvalsAsked += Int(number("vox.confirmations.asked"))
            day.approvalsGiven += Int(number("vox.confirmations.given"))
            day.interruptions += Int(number("vox.interruptions"))
            day.errors += Int(number("vox.errors"))
            if a["vox.latency.total_ms"] != nil {
                let latency = number("vox.latency.total_ms")
                day.latencyMsTotal += latency
                day.latencyCount += 1
                day.latencyMsMax = max(day.latencyMsMax, latency)
            }
            days[key] = day
        }
        let next = page["next_cursor"] as? String
        return (days, next?.isEmpty == false ? next : nil)
    }
}
