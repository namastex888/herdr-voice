import Foundation
import HerdrVoiceCore

/// The companion's API keys. They never go in the configuration tree: they live in the login Keychain, under the
/// same service names herdr-voice uses (OPENAI_API_KEY, XAI_API_KEY, GEMINI_API_KEY), so one setup serves both.
/// Everything else the companion is set to (voice model, voice, routing) is in the tree's `settings` entry.
@MainActor final class CompanionKeys: ObservableObject {
    /// The cloud voices the companion offers. Local OpenLive needs a source checkout, so it stays with the plugin.
    nonisolated static let providers: [Provider] = [.grok, .openai, .gemini]
    static let jevService = "TYPESAFE_API_KEY"
    /// Where MeetingPulse keeps its Jev key; imported only when the user asks (reading it can raise a Keychain prompt).
    static let meetingPulseJevService = "local.meetingpulse.native.jev"

    /// Bumped when a key is saved, so views that show which keys exist redraw.
    @Published private(set) var revision = 0
    private let environment = ProcessInfo.processInfo.environment

    func key(for provider: Provider) -> String? {
        provider.apiKey(environment: environment)?.value
    }

    func hasKey(_ provider: Provider) -> Bool { key(for: provider) != nil }

    /// Stores a pasted key after tidying it; false when it doesn't look like a key.
    func saveKey(_ raw: String, for provider: Provider) -> Bool {
        guard let clean = Keychain.cleanKey(raw), Keychain.store(service: provider.keyEnv, value: clean) else { return false }
        revision += 1
        return true
    }

    var jevKey: String? {
        Keychain.password(service: Self.jevService) ?? environment["TYPESAFE_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    }

    func saveJevKey(_ raw: String) -> Bool {
        guard let clean = Keychain.cleanKey(raw), Keychain.store(service: Self.jevService, value: clean) else { return false }
        revision += 1
        return true
    }

    /// Copies MeetingPulse's Jev key into the companion's own Keychain item.
    func importJevKeyFromMeetingPulse() -> Bool {
        guard let key = Keychain.password(service: Self.meetingPulseJevService),
              Keychain.store(service: Self.jevService, value: key) else { return false }
        revision += 1
        return true
    }
}

/// The tree's `settings` entry as the app runs it, with the defaults filled in.
struct CompanionSettings: Equatable {
    /// The voice model the human picked; nil until they pick one (a migrated 0.1.0 choice counts).
    var provider: Provider?
    /// A voice name of the provider's; nil means its default.
    var voice: String?
    var routeWithJev: Bool
    var jevModel: String

    init(_ tree: ConfigTree) {
        let config = tree["settings"]?.config ?? ConfigTree.defaultSettings
        provider = config["provider"]?.string.flatMap(Provider.init(rawValue:)).flatMap {
            CompanionKeys.providers.contains($0) ? $0 : nil
        }
        voice = config["voice"]?.string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        routeWithJev = config["routeWithJev"]?.bool ?? true
        jevModel = config["jevModel"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? JevRouter.defaultModel
    }
}
