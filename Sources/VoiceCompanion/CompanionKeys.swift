import Foundation
import HerdrVoiceCore

/// The companion's preferences, in UserDefaults. Keys never go there: they live in the login Keychain, under the
/// same service names herdr-voice uses (OPENAI_API_KEY, XAI_API_KEY, GEMINI_API_KEY), so one setup serves both.
@MainActor final class CompanionSettings: ObservableObject {
    /// The cloud voices the companion offers. Local OpenLive needs a source checkout, so it stays with the plugin.
    static let providers: [Provider] = [.grok, .openai, .gemini]
    static let jevService = "TYPESAFE_API_KEY"
    /// Where MeetingPulse keeps its Jev key; imported only when the user asks (reading it can raise a Keychain prompt).
    static let meetingPulseJevService = "local.meetingpulse.native.jev"

    private let defaults = UserDefaults.standard
    private let environment = ProcessInfo.processInfo.environment

    @Published var provider: Provider {
        didSet { defaults.set(provider.rawValue, forKey: "provider") }
    }
    /// Switching these changes which tools exist, so they apply from the next launch.
    @Published var allowAppleScript: Bool {
        didSet { defaults.set(allowAppleScript, forKey: "allowAppleScript") }
    }
    @Published var allowShell: Bool {
        didSet { defaults.set(allowShell, forKey: "allowShell") }
    }
    @Published var routeWithJev: Bool {
        didSet { defaults.set(routeWithJev, forKey: "routeWithJev") }
    }
    @Published var jevModel: String {
        didSet { defaults.set(jevModel, forKey: "jevModel") }
    }

    init() {
        let saved = defaults.string(forKey: "provider").flatMap(Provider.init(rawValue:))
        let firstWithKey = Self.providers.first { $0.apiKey(environment: ProcessInfo.processInfo.environment) != nil }
        provider = saved.flatMap { Self.providers.contains($0) ? $0 : nil } ?? firstWithKey ?? .grok
        allowAppleScript = defaults.bool(forKey: "allowAppleScript")
        allowShell = defaults.bool(forKey: "allowShell")
        routeWithJev = defaults.object(forKey: "routeWithJev") as? Bool ?? true
        jevModel = defaults.string(forKey: "jevModel") ?? JevRouter.defaultModel
    }

    func key(for provider: Provider) -> String? {
        provider.apiKey(environment: environment)?.value
    }

    func hasKey(_ provider: Provider) -> Bool { key(for: provider) != nil }

    /// Stores a pasted key after tidying it; false when it doesn't look like a key.
    func saveKey(_ raw: String, for provider: Provider) -> Bool {
        guard let clean = Keychain.cleanKey(raw) else { return false }
        return Keychain.store(service: provider.keyEnv, value: clean)
    }

    var jevKey: String? {
        Keychain.password(service: Self.jevService) ?? environment["TYPESAFE_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    }

    func saveJevKey(_ raw: String) -> Bool {
        guard let clean = Keychain.cleanKey(raw) else { return false }
        return Keychain.store(service: Self.jevService, value: clean)
    }

    /// Copies MeetingPulse's Jev key into the companion's own Keychain item.
    func importJevKeyFromMeetingPulse() -> Bool {
        guard let key = Keychain.password(service: Self.meetingPulseJevService) else { return false }
        return Keychain.store(service: Self.jevService, value: key)
    }

    /// Jev when it's on and has a key; nil means routing by words alone.
    var jevRouter: JevRouter? {
        guard routeWithJev, let key = jevKey else { return nil }
        return JevRouter(key: key, model: jevModel)
    }
}
