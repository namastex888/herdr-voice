import Foundation

/// docs/providers.md: one row per `Provider`, one column per `WireCapabilities` flag, generated from the code.
/// `herdr-voice providers` prints it, and a test fails when the committed file differs.
public enum ProviderTable {
    public static func markdown() -> String {
        let flags = Provider.allCases[0].capabilities.flags.map(\.name)
        var lines = [
            "# Providers",
            "",
            "Generated from `Provider` and each wire's `WireCapabilities` by `swift run herdr-voice providers > docs/providers.md`.",
            "Don't edit it by hand: a test fails when it differs from the generator, and WireConformanceTests holds every",
            "wire to its row. `scripts/provider-contract` checks the cloud rows against the live APIs.",
            "",
            "| Provider | Model | Endpoint | " + flags.map { "`\($0)`" }.joined(separator: " | ") + " |",
            "|" + String(repeating: "---|", count: 3 + flags.count),
        ]
        for provider in Provider.allCases {
            let cells = ["\(provider.menuTitle) (`\(provider.rawValue)`)", "`\(provider.model)`", "`\(provider.endpoint)`"]
                + provider.capabilities.flags.map { $0.value ? "yes" : "no" }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        lines += [
            "",
            "Models are the defaults: HERDR_VOICE_GEMINI_MODEL picks another Gemini model, and HERDR_LOCAL_BRAIN_MODEL",
            "another brain for Local OpenLive.",
            "",
        ]
        lines += flags.map { "- `\($0)`: \(WireCapabilities.meanings[$0] ?? "undocumented")" }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The plan `scripts/provider-probe.swift` runs against a live provider: where to connect, how the key goes in, and
/// the exact messages this provider's wire sends for setup, a narrowed tool update and an instruction update. The
/// probe can't link this package, so the messages come from here and stay the real ones.
public enum ProviderContract {
    /// How many of the tools the narrowed update keeps.
    public static let narrowedCount = 3
    public static let replacedInstructions = "[contract check] These instructions replace the ones from setup."

    public static func plan(for provider: Provider, tools: [[String: Any]],
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: Any] {
        let wire = provider.makeWire(environment: environment)
        let all = ToolList(tools), narrowed = ToolList(Array(tools.prefix(narrowedCount)))
        let steps: [[String: Any]] = [
            ["name": "setup", "tools": all.names, "instructions": voiceInstructions,
             "messages": wire.encode(.setup(instructions: voiceInstructions, voice: provider.defaultVoice,
                                            resumeHandle: nil, tools: all))],
            ["name": "updateTools", "tools": narrowed.names, "messages": wire.encode(.updateTools(narrowed))],
            ["name": "updateInstructions", "instructions": replacedInstructions,
             "messages": wire.encode(.updateInstructions(replacedInstructions))],
        ]
        return ["provider": provider.rawValue, "keychainService": provider.keyEnv, "url": provider.url.absoluteString,
                "auth": auth(provider), "steps": steps]
    }

    /// How `Provider.request(key:)` carries the key, found by building a request with a stand-in key: a header whose
    /// value has `{key}` where the key goes, or the name of a query parameter.
    static func auth(_ provider: Provider) -> [String: String] {
        let standIn = "contract-stand-in-key"
        let request = provider.request(key: standIn)
        if let (name, value) = request.allHTTPHeaderFields?.first(where: { $0.value.contains(standIn) }) {
            return ["header": name, "value": value.replacingOccurrences(of: standIn, with: "{key}")]
        }
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        if let item = items.first(where: { $0.value == standIn }) { return ["query": item.name] }
        return [:]
    }
}
