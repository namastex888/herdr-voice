import Foundation

/// What one OpenAI realtime response used, from `response.done`'s `usage`. The input counts include the cached
/// tokens, which are billed at the cached rate.
public struct RealtimeUsage: Codable, Equatable, Sendable {
    public var inputTextTokens = 0
    public var inputAudioTokens = 0
    public var cachedTextTokens = 0
    public var cachedAudioTokens = 0
    public var outputTextTokens = 0
    public var outputAudioTokens = 0

    public init(inputTextTokens: Int = 0, inputAudioTokens: Int = 0, cachedTextTokens: Int = 0,
                cachedAudioTokens: Int = 0, outputTextTokens: Int = 0, outputAudioTokens: Int = 0) {
        self.inputTextTokens = inputTextTokens
        self.inputAudioTokens = inputAudioTokens
        self.cachedTextTokens = cachedTextTokens
        self.cachedAudioTokens = cachedAudioTokens
        self.outputTextTokens = outputTextTokens
        self.outputAudioTokens = outputAudioTokens
    }

    public var inputTokens: Int { inputTextTokens + inputAudioTokens }
    public var outputTokens: Int { outputTextTokens + outputAudioTokens }
    public var totalTokens: Int { inputTokens + outputTokens }

    public static func + (a: RealtimeUsage, b: RealtimeUsage) -> RealtimeUsage {
        RealtimeUsage(inputTextTokens: a.inputTextTokens + b.inputTextTokens,
                      inputAudioTokens: a.inputAudioTokens + b.inputAudioTokens,
                      cachedTextTokens: a.cachedTextTokens + b.cachedTextTokens,
                      cachedAudioTokens: a.cachedAudioTokens + b.cachedAudioTokens,
                      outputTextTokens: a.outputTextTokens + b.outputTextTokens,
                      outputAudioTokens: a.outputAudioTokens + b.outputAudioTokens)
    }

    /// The usage in a `response.done` event, or nil when it has none (a cancelled response may not).
    public static func fromResponseDone(_ text: String) -> RealtimeUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              obj["type"] as? String == "response.done",
              let usage = (obj["response"] as? [String: Any])?["usage"] as? [String: Any] else { return nil }
        func int(_ dict: [String: Any]?, _ key: String) -> Int { (dict?[key] as? NSNumber)?.intValue ?? 0 }
        let input = usage["input_token_details"] as? [String: Any]
        let cached = input?["cached_tokens_details"] as? [String: Any]
        let output = usage["output_token_details"] as? [String: Any]
        var result = RealtimeUsage(inputTextTokens: int(input, "text_tokens"), inputAudioTokens: int(input, "audio_tokens"),
                                   cachedTextTokens: int(cached, "text_tokens"), cachedAudioTokens: int(cached, "audio_tokens"),
                                   outputTextTokens: int(output, "text_tokens"), outputAudioTokens: int(output, "audio_tokens"))
        // Without the breakdown the totals count as audio, which is what a realtime voice turn mostly is.
        if input == nil { result.inputAudioTokens = int(usage, "input_tokens") }
        if output == nil { result.outputAudioTokens = int(usage, "output_tokens") }
        return result
    }
}

/// What each voice model costs, versioned: every cost Vox records names the table it was priced with. Prices are the
/// providers' published list prices on the date of the version; Settings shows them.
public struct PriceTable: Equatable, Sendable {
    /// USD per 1M tokens.
    public struct TokenPrices: Equatable, Sendable {
        public let audioIn, audioCachedIn, audioOut, textIn, textCachedIn, textOut: Double
    }

    public enum Basis: Equatable, Sendable {
        /// Billed by tokens, read from each response's usage.
        case tokens(TokenPrices)
        /// Billed (or estimated) by the minute: USD per connected minute, and per minute of her speech.
        case minutes(connected: Double, spoken: Double)
        case free
    }

    public struct Row: Equatable, Sendable {
        public let provider: Provider
        public let model: String
        public let basis: Basis
        /// The cost is an estimate (the provider bills otherwise than Vox can measure).
        public let estimated: Bool
        /// Where the price comes from, in words.
        public let source: String

        /// One line for Settings.
        public var summary: String {
            switch basis {
            case .tokens(let p):
                return String(format: "audio $%g in / $%g out, text $%g in / $%g out, cached $%g per 1M tokens",
                              p.audioIn, p.audioOut, p.textIn, p.textOut, p.audioCachedIn)
            case .minutes(let connected, let spoken):
                var parts: [String] = []
                if connected > 0 { parts.append(String(format: "$%g per connected minute", connected)) }
                if spoken > 0 { parts.append(String(format: "$%g per minute she speaks", spoken)) }
                return parts.joined(separator: " + ") + (estimated ? " (estimated)" : "")
            case .free:
                return "free (runs on this Mac)"
            }
        }
    }

    public let version: String
    public let rows: [Row]

    public func row(_ provider: Provider) -> Row? { rows.first { $0.provider == provider } }

    /// The cost of one response's usage, for a model billed by tokens; 0 otherwise.
    public func cost(_ usage: RealtimeUsage, provider: Provider) -> Double {
        guard case .tokens(let p)? = row(provider)?.basis else { return 0 }
        let textIn = Double(max(0, usage.inputTextTokens - usage.cachedTextTokens))
        let audioIn = Double(max(0, usage.inputAudioTokens - usage.cachedAudioTokens))
        let usd = textIn * p.textIn + Double(usage.cachedTextTokens) * p.textCachedIn
            + audioIn * p.audioIn + Double(usage.cachedAudioTokens) * p.audioCachedIn
            + Double(usage.outputTextTokens) * p.textOut + Double(usage.outputAudioTokens) * p.audioOut
        return usd / 1_000_000
    }

    /// The cost of time, for a model billed (or estimated) by the minute; 0 otherwise.
    public func cost(connectedSeconds: Double, spokenSeconds: Double, provider: Provider) -> Double {
        guard case .minutes(let connected, let spoken)? = row(provider)?.basis else { return 0 }
        return connectedSeconds / 60 * connected + spokenSeconds / 60 * spoken
    }

    /// The table in use.
    public static let current = PriceTable(version: "2026-10-15", rows: [
        Row(provider: .openai, model: "gpt-realtime-2.1",
            basis: .tokens(TokenPrices(audioIn: 32, audioCachedIn: 0.40, audioOut: 64,
                                       textIn: 4, textCachedIn: 0.40, textOut: 24)),
            estimated: false, source: "OpenAI API pricing, 2026-10-15; from each response's usage"),
        Row(provider: .grok, model: "grok-voice-3.0", basis: .minutes(connected: 0.08, spoken: 0),
            estimated: false, source: "xAI models and pricing, 2026-10-15; connected minutes (typed text not counted)"),
        Row(provider: .gemini, model: "gemini-3.8-live", basis: .minutes(connected: 0.005, spoken: 0.018),
            estimated: true, source: "Gemini API pricing, 2026-10-15: audio in by connected minutes, audio out by her "
                + "spoken minutes; billed by tokens, so an estimate"),
        Row(provider: .local, model: "Local OpenLive", basis: .free, estimated: false, source: "runs on this Mac"),
    ])
}
