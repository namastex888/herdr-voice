import Foundation
import Testing
@testable import HerdrVoiceCore

// MARK: a protobuf reader, to check what the encoder wrote

private struct Field {
    let number: Int
    let wire: Int
    var varint: UInt64 = 0
    var bytes = Data()

    var string: String { String(decoding: bytes, as: UTF8.self) }
}

private func fields(_ data: Data) -> [Field] {
    var out: [Field] = [], i = data.startIndex
    func varint() -> UInt64 {
        var value: UInt64 = 0, shift: UInt64 = 0
        while i < data.endIndex {
            let byte = data[i]
            i += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { break }
            shift += 7
        }
        return value
    }
    while i < data.endIndex {
        let key = varint()
        var field = Field(number: Int(key >> 3), wire: Int(key & 7))
        switch field.wire {
        case 0: field.varint = varint()
        case 1:
            field.bytes = data[i..<i + 8]
            i += 8
        case 2:
            let length = Int(varint())
            field.bytes = data[i..<i + length]
            i += length
        default: return out
        }
        out.append(field)
    }
    return out
}

private func first(_ data: Data, _ number: Int) -> Field? { fields(data).first { $0.number == number } }
private func all(_ data: Data, _ number: Int) -> [Field] { fields(data).filter { $0.number == number } }

/// A KeyValue's key and its AnyValue rendered as text.
private func keyValue(_ data: Data) -> (String, String) {
    let key = first(data, 1)?.string ?? ""
    guard let any = first(data, 2)?.bytes, let value = fields(any).first else { return (key, "") }
    switch value.number {
    case 1: return (key, value.string)
    case 2, 3: return (key, String(value.varint))
    case 4: return (key, String(Double(bitPattern: value.bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })))
    case 5: return (key, all(value.bytes, 1).map { first($0.bytes, 1)?.string ?? "" }.joined(separator: ","))
    default: return (key, "?")
    }
}

private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

private func sampleTurn() -> TurnRecord {
    var turn = TurnRecord(id: "0123456789abcdef0123456789abcdef", provider: "openai", model: "gpt-realtime-2.1",
                          start: t0, end: t0.addingTimeInterval(6))
    turn.speechEnd = t0.addingTimeInterval(2)
    turn.submitted = t0.addingTimeInterval(2.5)
    turn.firstAudio = t0.addingTimeInterval(3.4)
    turn.route = TurnRecord.Route(skill: "harness.herdr", source: "jev", confidence: 0.9, milliseconds: 120)
    turn.tools = [TurnRecord.Tool(name: "list_agents", start: t0.addingTimeInterval(2.6), end: t0.addingTimeInterval(2.7),
                                  outcome: .ok),
                  TurnRecord.Tool(name: "prompt_agent", start: t0.addingTimeInterval(2.8), end: t0.addingTimeInterval(3.1),
                                  outcome: .ok, delegation: true, target: "claude-2")]
    turn.confirmationsAsked = 1
    turn.usage = RealtimeUsage(inputAudioTokens: 900, outputAudioTokens: 300)
    turn.costUSD = 0.0480
    turn.userWords = 6
    return turn
}

@Test func aTurnBecomesOpenInferenceSpansWithItsBreakdownAndNoWords() throws {
    let spans = TurnSpans.spans(sampleTurn(), session: "2026-10-15/101500-abcd")
    #expect(spans.map(\.name) == ["turn", "reply", "list_agents", "delegate claude-2"])
    let turn = spans[0]
    #expect(OTLP.hex(turn.traceID) == "0123456789abcdef0123456789abcdef" && turn.parentSpanID == nil)
    #expect(spans.dropFirst().allSatisfy { $0.parentSpanID == turn.spanID && $0.traceID == turn.traceID })
    #expect(Set(spans.map(\.spanID)).count == 4)
    let connection = TurnSpans.connection(ConnectionRecord(provider: "grok", model: "grok-voice-3.0", start: t0,
                                                           end: t0.addingTimeInterval(60), connectedSeconds: 60,
                                                           costUSD: 0.08))
    #expect(connection.name == "connection" && connection.attribute("vox.cost.basis") == .string("minutes"))
    #expect(turn.attribute("openinference.span.kind") == .string("CHAIN"))
    #expect(turn.attribute("vox.latency.total_ms").map { if case .double(let v) = $0 { abs(v - 1400) < 0.01 } else { false } } == true)
    #expect(turn.attribute("vox.route.source") == .string("jev") && turn.attribute("vox.route.confidence") == .double(0.9))
    #expect(turn.attribute("vox.tools") == .strings(["list_agents", "prompt_agent"]))
    #expect(turn.attribute("llm.token_count.total") == .int(1200) && turn.attribute("session.id") != nil)
    #expect(spans[1].attribute("openinference.span.kind") == .string("LLM"))
    #expect(spans[2].attribute("openinference.span.kind") == .string("TOOL"))
    #expect(spans[3].attribute("openinference.span.kind") == .string("AGENT")
            && spans[3].attribute("vox.delegation.agent") == .string("claude-2"))
    // Metadata only: no transcript or tool input/output anywhere.
    let keys = spans.flatMap { $0.attributes.map(\.key) }
    #expect(!keys.contains { $0.hasPrefix("input.") || $0.hasPrefix("output.") || $0.contains("arguments") })
}

@Test func theExportRequestIsWellFormedProtobufForThePhoenixProject() throws {
    let spans = TurnSpans.spans(sampleTurn())
    let body = OTLP.encode(spans, resource: [("service.name", .string("vox")), ("openinference.project.name", .string("vox"))],
                           scope: "vox", version: "0.4")
    let resourceSpans = try #require(first(body, 1)).bytes
    let resource = try #require(first(resourceSpans, 1)).bytes
    #expect(all(resource, 1).map { keyValue($0.bytes) }.contains { $0 == ("openinference.project.name", "vox") })
    let scopeSpans = try #require(first(resourceSpans, 2)).bytes
    let scope = try #require(first(scopeSpans, 1)).bytes
    #expect(first(scope, 1)?.string == "vox")
    let encoded = all(scopeSpans, 2).map(\.bytes)
    #expect(encoded.count == spans.count)
    let root = encoded[0]
    #expect(first(root, 1)?.bytes.count == 16 && first(root, 2)?.bytes.count == 8 && first(root, 4) == nil)
    #expect(first(root, 5)?.string == "turn" && first(root, 6)?.varint == 1)
    let start = try #require(first(root, 7)).bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    #expect(start == 1_760_000_000 * 1_000_000_000)
    let attributes = Dictionary(all(root, 9).map { keyValue($0.bytes) }, uniquingKeysWith: { a, _ in a })
    #expect(attributes["vox.tools.count"] == "2" && attributes["vox.cost.usd"] == "0.048")
    #expect(attributes["vox.tools"] == "list_agents,prompt_agent" && attributes["vox.turn.typed"] == "0")
    let status = try #require(first(root, 15)).bytes
    #expect(first(status, 3)?.varint == 1) // status OK
    #expect(first(encoded[3], 4)?.bytes == first(root, 2)?.bytes)       // a child names its parent
}

@Test func phoenixSettingsDefaultToTheLocalProjectVox() {
    let config = PhoenixConfig(nil)
    #expect(config.enabled && config.project == "vox")
    #expect(config.tracesURL?.absoluteString == "http://127.0.0.1:6006/v1/traces")
    let full = PhoenixConfig(.object(["endpoint": .string("https://phoenix.example.com/v1/traces"), "enabled": .bool(false)]))
    #expect(full.tracesURL?.absoluteString == "https://phoenix.example.com/v1/traces" && !full.enabled)
    #expect(PhoenixConfig(full.json) == full)
    let url = config.spansURL(name: "turn", since: t0)?.absoluteString ?? ""
    #expect(url.hasPrefix("http://127.0.0.1:6006/v1/projects/vox/spans?name=turn&start_time=2025-10-09T"))
    #expect(PhoenixConfig.headers(apiKey: "k")["Authorization"] == "Bearer k")
    #expect(PhoenixConfig.headers(apiKey: nil)["Authorization"] == nil)
    #expect(PhoenixConfig(.object(["endpoint": .string("not a url")])).tracesURL == nil)
}

// MARK: the exporter, against a stub transport

private final class StubPhoenix: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [(URLRequest, Data)] = []
    nonisolated(unsafe) static var status = 200
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let status = Self.lock.withLock {
            Self.requests.append((request, request.httpBody ?? body))
            return Self.status
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubPhoenix.self]
    return URLSession(configuration: configuration)
}

private func flushed(_ exporter: PhoenixExporter) async -> PhoenixExporter.Outcome? {
    await withCheckedContinuation { continuation in exporter.flush { continuation.resume(returning: $0) } }
}

@Test func spansGoOutInBatchesWithTheKeyAndAFailedBatchIsDropped() async throws {
    StubPhoenix.lock.withLock {
        StubPhoenix.requests = []
        StubPhoenix.status = 200
    }
    let exporter = PhoenixExporter(config: PhoenixConfig(), apiKey: "secret", session: stubSession())
    exporter.export(TurnSpans.spans(sampleTurn()))
    let sentOutcome = await flushed(exporter)
    let sent = try #require(sentOutcome)
    #expect(sent.ok && sent.spans == 4)
    let captured = StubPhoenix.lock.withLock { StubPhoenix.requests.first }
    let (request, body) = try #require(captured)
    #expect(request.url?.absoluteString == "http://127.0.0.1:6006/v1/traces" && request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-protobuf")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    let resourceSpans = try #require(first(body, 1)).bytes
    let scopeSpans = try #require(first(resourceSpans, 2)).bytes
    #expect(all(scopeSpans, 2).count == 4)

    StubPhoenix.lock.withLock { StubPhoenix.status = 503 }
    exporter.export(TurnSpans.spans(sampleTurn()))
    let refusedOutcome = await flushed(exporter)
    let refused = try #require(refusedOutcome)
    #expect(!refused.ok && exporter.droppedSpans == 4 && exporter.queuedSpans == 0)

    exporter.configure(PhoenixConfig(enabled: false), apiKey: nil)
    exporter.export(TurnSpans.spans(sampleTurn()))
    let off = await flushed(exporter)
    #expect(off == nil && exporter.queuedSpans == 0)
}

@Test func historyReadsTurnSpansBackPerDay() throws {
    let page = #"""
    {"data":[
      {"name":"turn","start_time":"2025-10-09T12:00:00.000000+00:00","attributes":{"vox.cost.usd":0.05,
       "vox.cost.basis":"tokens","vox.tools.count":2,"vox.confirmations.asked":1,"vox.latency.total_ms":900,
       "llm.provider":"openai"}},
      {"name":"turn","start_time":"2025-10-09T13:00:00+00:00","attributes":{"vox":{"cost":{"usd":0.004,
       "basis":"minutes"},"errors":1},"llm":{"provider":"grok"}}},
      {"name":"connection","start_time":"2025-10-09T12:59:00+00:00","attributes":{"vox.cost.usd":0.01,
       "vox.connected_seconds":450,"llm.provider":"grok"}},
      {"name":"turn","start_time":"2025-10-09T14:00:00+00:00","attributes":{"vox.selftest":true,"vox.cost.usd":9}},
      {"name":"list_agents","start_time":"2025-10-09T12:00:01+00:00","attributes":{}}
    ],"next_cursor":"abc"}
    """#
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let read = try #require(PhoenixHistory.days(fromPage: Data(page.utf8), calendar: utc))
    let day = try #require(read.days["2025-10-09"])
    #expect(day.turns == 2 && day.actions == 2 && day.approvalsAsked == 1 && day.errors == 1)
    // The token-billed turn and the connection's minutes; the minute-billed turn's own share isn't counted twice.
    #expect(abs(day.totalCost - 0.06) < 1e-9 && day.connectedSeconds["grok"] == 450)
    #expect(day.latencyCount == 1 && read.next == "abc")
}
