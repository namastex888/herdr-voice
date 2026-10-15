import AppKit
import HerdrVoiceCore
import VoiceEngine

/// Owns the companion: the skill registry (the configuration tree and its components), routing, the voice session,
/// the chat panel, the orb and the menu bar item. The tree is the one record of what she is set to: the app reads it
/// after every settle and changes it only through the registry's human edits, so the voice's own proposals, a revert
/// and a reset all reach the live session the same way. Every user turn, spoken or typed, is routed to a learned
/// skill or a harness's controls while the voice answers.
@MainActor final class CompanionController: ObservableObject {
    struct ActionInfo: Hashable {
        let name: String
        let description: String
    }

    struct HarnessInfo: Identifiable {
        let id: String
        /// `mac`, `herdr`, `shell`.
        let name: String
        let title: String
        let status: EntryStatus
        let actions: [ActionInfo]

        var on: Bool { status != .disabled }

        var statusText: String {
            switch status {
            case .active: "On"
            case .disabled: "Off"
            case .inactive where name == "herdr": "Not installed (no herdr command found)"
            case .inactive(let reason): "Not available: \(reason)"
            case .failed(let error): "Failed: \(error)"
            }
        }
    }

    struct SkillInfo: Identifiable {
        let skill: Skill
        let status: EntryStatus
        var id: String { skill.entryID }
    }

    /// Turns kept as context for routing.
    static let routingContext = 6
    /// How often to look again for a harness that appeared or went away (Herdr installed while she runs).
    static let refreshInterval: TimeInterval = 60

    let keys: CompanionKeys
    let chat = ChatModel()
    let registry: SkillRegistry
    @Published var tab: CompanionTab = .chat
    @Published private(set) var tree: ConfigTree
    @Published private(set) var harnesses: [HarnessInfo] = []
    @Published private(set) var skills: [SkillInfo] = []
    /// The change log, newest first.
    @Published private(set) var changes: [ChangeRecord] = []
    @Published private(set) var metrics = GrowthMetrics()
    /// The voice model in use, or the one to start once it has a key.
    @Published private(set) var provider: Provider = .grok
    /// What came of the human's last edit, shown on the Skills and Settings tabs.
    @Published var notice = ""
    private var router: any SkillRouter = WordRouter()
    private(set) var session: Realtime?
    private let configDirectory: URL?
    private var window: ChatWindow?
    private var orb: Orb?
    private var statusItem: NSStatusItem?
    private var recentTurns: [String] = []
    private var refreshTimer: Timer?
    private var activeObserver: NSObjectProtocol?

    /// `store` is where `config.json` lives; the first time it is built from 0.1.0's settings (`legacyDefaults`) and
    /// skills folder. nil keeps the configuration in memory. `gate` holds proposals until the human's own yes.
    init(keys: CompanionKeys = CompanionKeys(),
         store: CompanionStore? = CompanionStore(directory: CompanionStore.defaultDirectory),
         legacyDefaults: UserDefaults? = .standard, gate: ConfirmGate = .shared) {
        self.keys = keys
        configDirectory = store?.directory
        registry = SkillRegistry(store: store, gate: gate, legacyDefaults: legacyDefaults)
        tree = registry.tree
        reload()
        provider = chosenProvider()
        chat.provider = provider
        refreshRouter()
        registry.onChange { [weak self] emission in
            DispatchQueue.main.async { self?.registryChanged(emission) }
        }
    }

    // MARK: what the tree says

    var settings: CompanionSettings { CompanionSettings(tree) }

    func identity(_ key: String) -> String { tree["identity"]?.config[key]?.string ?? "" }

    var name: String {
        let name = identity("name").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Companion" : name
    }

    var facts: [String] { (tree["memory"]?.config["facts"]?.array ?? []).compactMap(\.string) }

    /// The voice named in the tree, else the provider's own (voice names differ per provider).
    var voice: String { settings.voice ?? provider.defaultVoice }

    var appleScriptOn: Bool { tree["harness.mac"]?.config["appleScript"]?.bool ?? false }

    /// The provider the tree names; until the human picks one, the session's, else the first with a key, else Grok
    /// (where a new user is pointed to add a key).
    private func chosenProvider() -> Provider {
        settings.provider ?? session?.provider ?? CompanionKeys.providers.first { keys.hasKey($0) } ?? .grok
    }

    /// Copies what the views show out of the registry.
    private func reload() {
        tree = registry.tree
        harnesses = registry.harnesses.map { harness in
            HarnessInfo(id: harness.entryID, name: harness.name, title: harness.title, status: harness.status,
                        actions: harness.actions.definitions.map {
                            ActionInfo(name: $0["name"] as? String ?? "", description: $0["description"] as? String ?? "")
                        })
        }
        skills = registry.skills.map { SkillInfo(skill: $0, status: registry.status(of: $0.entryID) ?? .inactive("unknown")) }
        changes = registry.changes.reversed()
        metrics = registry.metrics
        chat.activeSkills = registry.active
    }

    // MARK: lifecycle

    func start() {
        let window = ChatWindow(content: CompanionView(controller: self, chat: chat, keys: keys))
        self.window = window
        installStatusItem()
        installOrb()
        Hotkey.registerMute { [weak self] in self?.toggleMute() }
        startSession()
        watchForHarnesses()
        window.show()
    }

    /// Opens the voice session for the chosen provider, or points the user at Settings when it has no key yet.
    private func startSession() {
        provider = chosenProvider()
        chat.provider = provider
        guard let key = keys.key(for: provider) else {
            chat.note("Add a \(provider.menuTitle) API key in Settings to start talking.")
            tab = .settings
            return
        }
        let session = Realtime(provider: provider, key: key, voice: voice, host: registry,
                               instructions: registry.instructions, greeting: registry.greeting)
        session.setTools(registry.activeTools)
        session.onEvent = { [weak self] in self?.chat.append($0) }
        session.onUserTurn = { [weak self] in self?.route($0) }
        session.audio.onSpeakingChanged = { [weak session] speaking in
            Hotkey.setStopKey(active: speaking) { session?.stopSpeech(reason: "Esc") }
        }
        do {
            try session.start()
        } catch {
            chat.note("The microphone didn't start: \(error.localizedDescription). Allow it in System Settings → "
                      + "Privacy & Security → Microphone.")
            return
        }
        self.session = session
    }

    /// A harness that appears later (Herdr installed) or goes away is picked up when the app comes forward and once
    /// a minute.
    private func watchForHarnesses() {
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Reconciles again (a settle, if anything changed, arrives through `registryChanged`) and re-reads the growth
    /// metrics, which a skill's run bumps without a settle.
    func refresh() {
        registry.refresh()
        metrics = registry.metrics
    }

    func quit() {
        session?.shutdown()
        // A moment for the WebSocket close frame to go out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    // MARK: talking and typing

    func send(_ text: String) {
        guard let session else {
            chat.append(.you(text))
            chat.note("Add a \(provider.menuTitle) API key in Settings first.")
            tab = .settings
            return
        }
        session.sendTyped(text)
    }

    func toggleMute() {
        session?.toggleMute()
        chat.muted = session?.muted ?? false
    }

    // MARK: routing

    /// Asks the router which learned skill or harness this turn needs, over the registry's route options, without
    /// holding up the voice: the answer narrows the tools for the steps that follow, and `use_skill` covers anything
    /// it misses.
    private func route(_ text: String) {
        recentTurns = Array((recentTurns + [text]).suffix(Self.routingContext))
        let router = router, options = registry.routeOptions, recent = Array(recentTurns.dropLast())
        Task { @MainActor [weak self] in
            guard let decision = await router.route(text, recent: recent, options: options), let self else { return }
            self.chat.lastRoute = decision
            if decision.skill != RouteDecision.chat { self.registry.activate(decision.skill) }
        }
    }

    /// Jev when the tree says so and it has a key; words otherwise.
    private func refreshRouter() {
        router = CompanionRouter(jev: jevRouter)
    }

    var jevRouter: JevRouter? {
        let settings = settings
        guard settings.routeWithJev, let key = keys.jevKey else { return nil }
        return JevRouter(key: key, model: settings.jevModel)
    }

    // MARK: settles

    /// One emission per settle: the live session gets the new tools, and the new instructions when they changed
    /// (Realtime ignores unchanged ones). Then the views catch up, and a changed voice model, voice or routing
    /// takes effect, whoever changed it.
    private func registryChanged(_ emission: RegistryEmission) {
        session?.setTools(emission.tools)
        session?.setInstructions(emission.instructions)
        session?.greeting = registry.greeting
        let before = settings
        reload()
        let after = settings
        if after.routeWithJev != before.routeWithJev || after.jevModel != before.jevModel { refreshRouter() }
        if after.provider != before.provider {
            followProvider()
        } else if after.voice != before.voice {
            session?.setVoice(voice)
        }
    }

    /// Moves the live session to the provider the tree names now (the human's pick, a revert or a reset), or starts
    /// one once that provider has a key.
    private func followProvider() {
        provider = chosenProvider()
        chat.provider = provider
        guard let key = keys.key(for: provider) else {
            chat.note("\(provider.menuTitle) has no API key yet; add one in Settings.")
            notice = "Add a \(provider.menuTitle) key below to talk with it."
            tab = .settings
            return
        }
        guard let session else { return startSession() }
        if session.provider != provider { session.switchProvider(to: provider, key: key, voice: voice) }
    }

    func title(ofSkill id: String) -> String {
        skills.first { $0.id == id }?.skill.title ?? harnesses.first { $0.id == id }?.title ?? id
    }

    // MARK: the human's own edits (each applies at once and is logged as theirs)

    /// Runs one human edit; what went wrong shows on the tab they're on.
    private func edit(_ change: () throws -> Void) {
        do {
            try change()
            notice = ""
        } catch {
            notice = "Couldn't change that: \(error)"
        }
    }

    func setHarness(_ id: String, on: Bool) {
        edit { try registry.setDisabled(id, !on) }
    }

    func setAppleScript(_ on: Bool) {
        edit { try registry.setField("harness.mac", "appleScript", .bool(on)) }
    }

    func forgetSkill(_ id: String) {
        edit { try registry.forgetSkill(id) }
    }

    func revert(_ changeID: String) {
        edit { try registry.revert(changeID) }
    }

    /// `name`, `role`, `personality` or `instructions`.
    func setIdentity(_ key: String, _ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != identity(key) else { return }
        // Without a name the identity entry would fail to load, and the voice would lose who it is.
        guard key != "name" || !value.isEmpty else {
            notice = "She needs a name."
            return
        }
        edit { try registry.setField("identity", key, .string(value)) }
    }

    func addFact(_ text: String) {
        let fact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty, !facts.contains(fact) else { return }
        edit { try registry.applyUserEdit("Remembered: \(fact)") { try Self.editFacts(&$0) { $0.append(fact) } } }
    }

    func removeFact(_ fact: String) {
        edit { try registry.applyUserEdit("Forgot: \(fact)") { try Self.editFacts(&$0) { $0.removeAll { $0 == fact } } } }
    }

    private static func editFacts(_ tree: inout ConfigTree, _ change: (inout [String]) -> Void) throws {
        guard var memory = tree["memory"] else { throw ComponentError("there is no memory entry") }
        var facts = (memory.config["facts"]?.array ?? []).compactMap(\.string)
        change(&facts)
        memory.config["facts"] = .array(facts.map(JSONValue.string))
        tree["memory"] = memory
    }

    /// The human's pick of voice model; the session follows when the settle arrives. Voice names differ per provider,
    /// so a voice set for the old one goes back to the new one's default in the same change.
    func chooseProvider(_ next: Provider) {
        guard next != settings.provider else { return }
        edit {
            try registry.applyUserEdit("Switched the voice model to \(next.menuTitle)") { tree in
                guard var entry = tree["settings"] else { throw ComponentError("there is no settings entry") }
                entry.config["provider"] = .string(next.rawValue)
                if entry.config["voice"]?.string != nil { entry.config["voice"] = .null }
                tree["settings"] = entry
            }
        }
    }

    /// Empty means the provider's default voice.
    func setVoiceName(_ text: String) {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard name != (settings.voice ?? "") else { return }
        edit { try registry.setField("settings", "voice", name.isEmpty ? .null : .string(name)) }
    }

    func setRouteWithJev(_ on: Bool) {
        guard on != settings.routeWithJev else { return }
        edit { try registry.setField("settings", "routeWithJev", .bool(on)) }
    }

    func setJevModel(_ text: String) {
        let model = text.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, model != settings.jevModel else { return }
        edit { try registry.setField("settings", "jevModel", .string(model)) }
    }

    /// No skills, the factory identity, memory and settings; the harnesses and the voice model stay. The change log
    /// keeps it, so it can be reverted like any other change.
    func resetToNewHire() {
        edit { try registry.resetToNewHire() }
        if notice.isEmpty { notice = "She's a new hire again. Skills → How I've changed can undo it." }
    }

    // MARK: keys (Keychain, never the tree)

    func saveKey(_ raw: String, for provider: Provider) {
        guard keys.saveKey(raw, for: provider) else {
            notice = "That doesn't look like a key."
            return
        }
        notice = "Saved the \(provider.menuTitle) key."
        followProvider()
    }

    func saveJevKey(_ raw: String) {
        notice = keys.saveJevKey(raw) ? "Saved the Jev key." : "That doesn't look like a key."
        refreshRouter()
    }

    func importJevKey() {
        notice = keys.importJevKeyFromMeetingPulse() ? "Imported the Jev key." : "No MeetingPulse key found."
        refreshRouter()
    }

    func openConfigFolder() {
        let folder = configDirectory ?? CompanionStore.defaultDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: orb and menu bar

    private func installOrb() {
        let orb = Orb(onClick: { [weak self] in self?.window?.toggle() },
                      menuChoices: { [weak self] in self?.orbMenu() ?? [] },
                      onQuit: { [weak self] in self?.quit() })
        orb.showInScreenCorner()
        orb.run { [weak self] in self?.frame() ?? Orb.Frame(mood: .offline, mic: 0, voice: 0, thinking: false) }
        self.orb = orb
    }

    private func orbMenu() -> [Orb.MenuChoice] {
        let chatShown = window?.isVisible ?? false
        var choices = [
            Orb.MenuChoice(title: chatShown ? "Hide chat" : "Show chat", checked: false, enabled: true) { [weak self] in
                self?.window?.toggle()
            },
            Orb.MenuChoice(title: chat.muted ? "Unmute" : "Mute", checked: false, enabled: session != nil,
                           separatorAfter: true) { [weak self] in self?.toggleMute() },
        ]
        choices += CompanionKeys.providers.map { provider in
            Orb.MenuChoice(title: provider.menuTitle, checked: provider == self.provider,
                           enabled: keys.hasKey(provider)) { [weak self] in self?.chooseProvider(provider) }
        }
        return choices
    }

    /// Drives the orb each frame, and keeps the chat's connection and mute state current.
    private func frame() -> Orb.Frame {
        guard let session else { return Orb.Frame(mood: .offline, mic: 0, voice: 0, thinking: false) }
        let audio = session.audio
        let connected = session.status == .live
        if chat.connected != connected { chat.connected = connected }
        if chat.muted != session.muted { chat.muted = session.muted }
        let mood = Activity.mood(loading: false, disconnected: session.status == .disconnected, dormant: session.dormant,
                                 muted: session.muted, speaking: audio.isSpeaking,
                                 agentsWorking: !session.busyAgents.isEmpty, micQuiet: audio.micLevel < 0.02)
        return Orb.Frame(mood: mood, mic: session.muted ? 0 : audio.micLevel, voice: audio.isSpeaking ? audio.outLevel : 0,
                         thinking: session.status != .disconnected && session.thinking)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Voice Companion")
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Show Chat") { [weak self] in self?.window?.show() })
        menu.addItem(ClosureMenuItem("Mute or Unmute (⌥⌘M)") { [weak self] in self?.toggleMute() })
        menu.addItem(ClosureMenuItem("Skills…") { [weak self] in
            self?.tab = .skills
            self?.window?.show()
        })
        menu.addItem(ClosureMenuItem("Settings…", key: ",") { [weak self] in
            self?.tab = .settings
            self?.window?.show()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Voice Companion", key: "q") { [weak self] in self?.quit() })
        item.menu = menu
        statusItem = item
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
