import Foundation

// OpenTelemetry spans in OTLP/HTTP protobuf (Phoenix's /v1/traces accepts protobuf only), written by hand: the few
// messages a trace export needs, with no dependency. Field numbers follow opentelemetry-proto's trace.proto,
// common.proto and resource.proto.

public enum OTLPValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case strings([String])
}

public struct OTLPSpan: Equatable, Sendable {
    /// 16 bytes, and 8 bytes for span ids.
    public var traceID: Data
    public var spanID: Data
    public var parentSpanID: Data?
    public var name: String
    /// 1 internal, 2 server, 3 client.
    public var kind: Int = 1
    public var start: Date
    public var end: Date
    public var attributes: [(key: String, value: OTLPValue)]
    /// An error's message, or nil for OK.
    public var error: String?

    public init(traceID: Data, spanID: Data, parentSpanID: Data? = nil, name: String, kind: Int = 1, start: Date,
                end: Date, attributes: [(key: String, value: OTLPValue)], error: String? = nil) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.name = name
        self.kind = kind
        self.start = start
        self.end = end
        self.attributes = attributes
        self.error = error
    }

    public static func == (a: OTLPSpan, b: OTLPSpan) -> Bool {
        a.traceID == b.traceID && a.spanID == b.spanID && a.parentSpanID == b.parentSpanID && a.name == b.name
            && a.kind == b.kind && a.start == b.start && a.end == b.end && a.error == b.error
            && a.attributes.map(\.key) == b.attributes.map(\.key) && a.attributes.map(\.value) == b.attributes.map(\.value)
    }

    public func attribute(_ key: String) -> OTLPValue? { attributes.first { $0.key == key }?.value }
}

/// Protobuf wire format, just enough of it.
public struct ProtoWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private mutating func tag(_ field: Int, _ wireType: UInt64) { varint(UInt64(field) << 3 | wireType) }

    public mutating func uint(_ field: Int, _ value: UInt64) {
        tag(field, 0)
        varint(value)
    }

    public mutating func int64(_ field: Int, _ value: Int64) {
        tag(field, 0)
        varint(UInt64(bitPattern: value))
    }

    public mutating func bool(_ field: Int, _ value: Bool) { uint(field, value ? 1 : 0) }

    public mutating func fixed64(_ field: Int, _ value: UInt64) {
        tag(field, 1)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func double(_ field: Int, _ value: Double) { fixed64(field, value.bitPattern) }

    public mutating func bytes(_ field: Int, _ value: Data) {
        tag(field, 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    public mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }

    public mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.data)
    }
}

public enum OTLP {
    /// An `ExportTraceServiceRequest`: one resource (the service and its Phoenix project), one scope, the spans.
    public static func encode(_ spans: [OTLPSpan], resource: [(key: String, value: OTLPValue)],
                              scope: String, version: String) -> Data {
        var request = ProtoWriter()
        request.message(1) { resourceSpans in                   // ExportTraceServiceRequest.resource_spans
            resourceSpans.message(1) { r in                       // ResourceSpans.resource
                for attribute in resource { r.message(1) { keyValue(&$0, attribute) } } // Resource.attributes
            }
            resourceSpans.message(2) { scopeSpans in              // ResourceSpans.scope_spans
                scopeSpans.message(1) { s in                      // ScopeSpans.scope
                    s.string(1, scope)
                    s.string(2, version)
                }
                for span in spans { scopeSpans.message(2) { encode(span, into: &$0) } } // ScopeSpans.spans
            }
        }
        return request.data
    }

    static func encode(_ span: OTLPSpan, into w: inout ProtoWriter) {
        w.bytes(1, span.traceID)
        w.bytes(2, span.spanID)
        if let parent = span.parentSpanID { w.bytes(4, parent) }
        w.string(5, span.name)
        w.uint(6, UInt64(span.kind))
        w.fixed64(7, nanos(span.start))
        w.fixed64(8, nanos(max(span.end, span.start)))
        for attribute in span.attributes { w.message(9) { keyValue(&$0, attribute) } }
        w.message(15) { status in                                 // Span.status
            if let error = span.error {
                status.string(2, error)
                status.uint(3, 2)                                 // STATUS_CODE_ERROR
            } else {
                status.uint(3, 1)                                 // STATUS_CODE_OK
            }
        }
    }

    static func keyValue(_ w: inout ProtoWriter, _ attribute: (key: String, value: OTLPValue)) {
        w.string(1, attribute.key)
        w.message(2) { anyValue(&$0, attribute.value) }
    }

    static func anyValue(_ w: inout ProtoWriter, _ value: OTLPValue) {
        switch value {
        case .string(let s): w.string(1, s)
        case .bool(let b): w.bool(2, b)
        case .int(let i): w.int64(3, Int64(i))
        case .double(let d): w.double(4, d)
        case .strings(let list):
            w.message(5) { array in                               // ArrayValue.values
                for item in list { array.message(1) { $0.string(1, item) } }
            }
        }
    }

    static func nanos(_ date: Date) -> UInt64 { UInt64(max(0, date.timeIntervalSince1970) * 1_000_000_000) }

    /// 16 bytes from 32 hex characters (a turn id), or nil.
    public static func traceID(hex: String) -> Data? {
        let chars = Array(hex.lowercased())
        guard chars.count == 32 else { return nil }
        var bytes = Data(capacity: 16)
        for i in stride(from: 0, to: 32, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// A span id inside a trace: the trace id's second half with its last byte set to `index` (0 for the root, so
    /// children are 1, 2, ...); never all zero.
    public static func spanID(trace: Data, index: Int) -> Data {
        var id = Data(trace.suffix(8))
        id[id.index(id.startIndex, offsetBy: 7)] = UInt8(truncatingIfNeeded: index)
        if id.allSatisfy({ $0 == 0 }) { id[id.startIndex] = 1 }
        return id
    }
}

/// A voice turn as OpenInference spans: the turn (CHAIN) with its latency breakdown, route, tools, questions,
/// interruptions and cost; the model's reply (LLM) with its tokens; each tool call (TOOL); each delegation to a coding
/// agent (AGENT). Metadata only: no transcript, no tool arguments, no outputs.
public enum TurnSpans {
    public static func spans(_ turn: TurnRecord, session: String? = nil, priceTable: String = PriceTable.current.version)
        -> [OTLPSpan] {
        let trace = OTLP.traceID(hex: turn.id) ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let root = OTLP.spanID(trace: trace, index: 0)
        var attributes: [(key: String, value: OTLPValue)] = [
            ("openinference.span.kind", .string("CHAIN")),
            ("vox.turn.id", .string(turn.id)),
            ("vox.turn.typed", .bool(turn.typed)),
            ("llm.provider", .string(turn.provider)),
            ("llm.model_name", .string(turn.model)),
            ("vox.tools.count", .int(turn.tools.count)),
            ("vox.confirmations.asked", .int(turn.confirmationsAsked)),
            ("vox.confirmations.given", .int(turn.confirmationsGiven)),
            ("vox.interruptions", .int(turn.interruptions)),
            ("vox.errors", .int(turn.errors)),
            ("vox.cost.usd", .double(turn.costUSD)),
            ("vox.cost.estimated", .bool(turn.costEstimated)),
            ("vox.cost.basis", .string(turn.usage != nil ? "tokens" : turn.costEstimated ? "minutes" : "none")),
            ("vox.cost.price_table", .string(priceTable)),
            ("vox.words.user", .int(turn.userWords)),
            ("vox.words.vox", .int(turn.voiceWords)),
            ("vox.latency.tools_ms", .double(turn.toolMs)),
        ]
        if let session { attributes.append(("session.id", .string(session))) }
        if !turn.tools.isEmpty { attributes.append(("vox.tools", .strings(turn.tools.map(\.name)))) }
        if let latency = turn.latencyMs { attributes.append(("vox.latency.total_ms", .double(latency))) }
        if let cooldown = turn.cooldownMs { attributes.append(("vox.latency.cooldown_ms", .double(cooldown))) }
        if let model = turn.modelMs { attributes.append(("vox.latency.model_ms", .double(model))) }
        if let route = turn.route {
            attributes += [("vox.route.skill", .string(route.skill)), ("vox.route.source", .string(route.source)),
                           ("vox.route.confidence", .double(route.confidence)),
                           ("vox.latency.route_ms", .double(route.milliseconds))]
        }
        if let usage = turn.usage { attributes += tokenAttributes(usage) }
        var spans = [OTLPSpan(traceID: trace, spanID: root, name: "turn", start: turn.start, end: turn.end,
                              attributes: attributes,
                              error: turn.errors > 0 ? "\(turn.errors) error\(turn.errors == 1 ? "" : "s")" : nil)]

        var index = 1
        if turn.firstAudio != nil || turn.usage != nil || turn.voiceWords > 0 {
            let from = turn.submitted ?? turn.speechEnd ?? turn.start
            var llm: [(key: String, value: OTLPValue)] = [
                ("openinference.span.kind", .string("LLM")),
                ("llm.provider", .string(turn.provider)), ("llm.model_name", .string(turn.model)),
                ("vox.cost.usd", .double(turn.costUSD)), ("vox.cost.estimated", .bool(turn.costEstimated)),
            ]
            if let usage = turn.usage { llm += tokenAttributes(usage) }
            if let first = turn.firstAudio { llm.append(("vox.latency.first_audio_ms", .double(max(0, first.timeIntervalSince(from) * 1000)))) }
            spans.append(OTLPSpan(traceID: trace, spanID: OTLP.spanID(trace: trace, index: index), parentSpanID: root,
                                  name: "reply", kind: 3, start: from, end: max(turn.end, from), attributes: llm))
            index += 1
        }
        for tool in turn.tools {
            let end = tool.end ?? turn.end
            var toolAttributes: [(key: String, value: OTLPValue)] = [
                ("openinference.span.kind", .string(tool.delegation ? "AGENT" : "TOOL")),
                ("tool.name", .string(tool.name)), ("vox.tool.outcome", .string(tool.outcome.rawValue)),
            ]
            if tool.delegation {
                toolAttributes.append(("vox.delegation", .bool(true)))
                if let target = tool.target { toolAttributes.append(("vox.delegation.agent", .string(target))) }
            }
            spans.append(OTLPSpan(traceID: trace, spanID: OTLP.spanID(trace: trace, index: index), parentSpanID: root,
                                  name: tool.delegation ? "delegate \(tool.target ?? tool.name)" : tool.name,
                                  start: tool.start, end: end, attributes: toolAttributes,
                                  error: tool.outcome == .error ? "the tool answered an error" : nil))
            index += 1
        }
        return spans
    }

    /// A stretch of connected time as one span, with what it cost where the model bills by the minute. History sums
    /// these with the token-billed turns, so a minute's cost is counted once.
    public static func connection(_ record: ConnectionRecord, priceTable: String = PriceTable.current.version) -> OTLPSpan {
        let trace = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        return OTLPSpan(traceID: trace, spanID: OTLP.spanID(trace: trace, index: 0), name: "connection",
                        start: record.start, end: record.end, attributes: [
                            ("openinference.span.kind", .string("CHAIN")),
                            ("llm.provider", .string(record.provider)), ("llm.model_name", .string(record.model)),
                            ("vox.connected_seconds", .double(record.connectedSeconds)),
                            ("vox.spoken_seconds", .double(record.spokenSeconds)),
                            ("vox.cost.usd", .double(record.costUSD)), ("vox.cost.estimated", .bool(record.estimated)),
                            ("vox.cost.basis", .string("minutes")), ("vox.cost.price_table", .string(priceTable)),
                        ])
    }

    static func tokenAttributes(_ usage: RealtimeUsage) -> [(key: String, value: OTLPValue)] {
        [("llm.token_count.prompt", .int(usage.inputTokens)), ("llm.token_count.completion", .int(usage.outputTokens)),
         ("llm.token_count.total", .int(usage.totalTokens)),
         ("llm.token_count.prompt_details.audio", .int(usage.inputAudioTokens)),
         ("llm.token_count.prompt_details.cache_read", .int(usage.cachedTextTokens + usage.cachedAudioTokens)),
         ("llm.token_count.completion_details.audio", .int(usage.outputAudioTokens))]
    }
}

/// Connected time with its cost, for a model billed by the minute: exported as a `connection` span.
public struct ConnectionRecord: Equatable, Sendable {
    public var provider: String
    public var model: String
    public var start: Date
    public var end: Date
    public var connectedSeconds: Double
    public var spokenSeconds: Double
    public var costUSD: Double
    public var estimated: Bool

    public init(provider: String, model: String, start: Date, end: Date, connectedSeconds: Double = 0,
                spokenSeconds: Double = 0, costUSD: Double = 0, estimated: Bool = false) {
        self.provider = provider
        self.model = model
        self.start = start
        self.end = end
        self.connectedSeconds = connectedSeconds
        self.spokenSeconds = spokenSeconds
        self.costUSD = costUSD
        self.estimated = estimated
    }
}
