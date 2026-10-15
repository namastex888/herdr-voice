import AppKit
import HerdrVoiceCore
import VoiceEngine

/// Owns the companion: the skill registry (the configuration tree and its components), routing, the voice session,
/// the phone (which is also the orb) and the menu bar item. The tree is the one record of what she is set to: the app reads it
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
    /// The phone's screen, shade and morph; the live levels its orb and light bar draw; the Mac's battery and network.
    let phone = PhoneModel()
    let live = LiveLevels()
    let device = DeviceStatus()
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
    var phoneWindow: PhoneWindow?
    /// Drives the orb, the light bar and the conversation's clock.
    var frameTimer: Timer?
    /// When the current conversation began: the assistant sheet shows only what was said since.
    @Published var conversationStarted = Date.distantPast
    private var statusItem: NSStatusItem?
    /// The status menu's delegate (menus hold theirs weakly).
    private var menuRebuilder: MenuRebuilder?
    private var recentTurns: [String] = []
    private var refreshTimer: Timer?
    private var activeObserver: NSObjectProtocol?
    private var muteDebounce = PressDebounce()
    /// What the companion harness drives.
    let appBridge: CompanionAppBridge
    /// Pause or Disconnect asked for by voice: done once she has said so (see `perform`).
    var deferredPress: (press: ControlPress, deadline: Date)?

    // Activation (see CompanionActivation.swift): when she listens, and the conversation's state for the UI.
    var turns = TurnTaking()
    var keyMonitor: ActivationKeyMonitor?
    var wakeWord: WakeWordSpotter?
    /// The conversation as the views show it.
    @Published var conversation: TurnTaking.Phase = .idle
    @Published var handsFree = false
    /// The activation key can't be watched (no Input Monitoring) or the wake word can't listen: what she does instead.
    @Published var activationNote = ""
    /// When the phone goes back into the orb by itself (see VoiceMode.swift), and why it's up, for the views.
    var minimizer = AutoMinimize()
    @Published var phoneReason: AutoMinimize.Reason?
    /// Watches for another app taking focus and for clicks in the phone.
    var voiceModeObservers: [Any] = []
    /// Where her questions wait for the user's own yes: while one waits, the phone stays up.
    let gate: ConfirmGate

    /// `store` is where `config.json` lives; the first time it is built from 0.1.0's settings (`legacyDefaults`) and
    /// skills folder. nil keeps the configuration in memory. `gate` holds proposals until the human's own yes.
    init(keys: CompanionKeys = CompanionKeys(),
         store: CompanionStore? = CompanionStore(directory: CompanionStore.defaultDirectory),
         legacyDefaults: UserDefaults? = .standard, gate: ConfirmGate = .shared) {
        self.keys = keys
        self.gate = gate
        configDirectory = store?.directory
        // Her own app's controls (the companion harness) run here, through the bridge, on the same gate the
        // session's heard words go to.
        let bridge = CompanionAppBridge()
        registry = SkillRegistry(store: store, factory: .companion(bridge, gate: gate), gate: gate,
                                 legacyDefaults: legacyDefaults)
        appBridge = bridge
        tree = registry.tree
        reload()
        provider = chosenProvider()
        bridge.attach(self)
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
        phone.theme = PhoneTheme(seed: accent)
        let window = PhoneWindow(model: phone, content: PhoneRoot(controller: self, model: phone, live: live, device: device))
        phoneWindow = window
        window.onFocusChange = { [weak self] in self?.updateEscape() }
        device.start()
        watchFocusAndTouches()
        installStatusItem()
        window.showOrb()
        startFrames()
        Hotkey.registerMute { [weak self] in self?.hotkeyPressed() }
        startSession()
        applyActivation()
        watchForHarnesses()
        // Without a key there's nothing to talk to yet: open on Settings, where the key goes.
        if session == nil { openPhone(.settings, activate: false) } else { showFirstRunHint() }
    }

    /// Opens the voice session for the chosen provider, or points the user at Settings when it has no key yet.
    private func startSession() {
        provider = chosenProvider()
        chat.provider = provider
        guard let key = keys.key(for: provider) else {
            chat.note("Add a \(provider.menuTitle) API key in Settings to start talking.")
            phone.screen = .settings
            return
        }
        let session = Realtime(provider: provider, key: key, voice: voice, host: registry,
                               instructions: registry.instructions, greeting: registry.greeting)
        session.setTools(registry.activeTools)
        attach(session)
        // Tap-to-talk and the wake word: nothing opens (or bills) until she's asked; the reply waits for the turn.
        session.deferReplies = settings.activation.opensOnRequest
        session.setStandby(settings.activation.opensOnRequest)
        do {
            try session.start()
        } catch {
            self.session = nil
            syncControls()
            chat.note("The microphone didn't start: \(error.localizedDescription). Allow it in System Settings → "
                      + "Privacy & Security → Microphone.")
            return
        }
    }

    /// Wires a session to the chat, routing and Esc, and makes it the one the controls drive. Before `start()`, so
    /// its first notes reach the chat; the self-test attaches one it never starts.
    func attach(_ session: Realtime) {
        session.onEvent = { [weak self] event in
            self?.chat.append(event)
            self?.sessionSaid(event)
        }
        session.onUserTurn = { [weak self] in self?.userSaid($0) }
        session.onSpeech = { [weak self] started in self?.activation(started ? .speechStarted : .speechStopped) }
        session.audio.onSpeakingChanged = { [weak self] _ in self?.updateEscape() }
        self.session = session
        syncControls()
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
            phone.screen = .settings
            return
        }
        session.sendTyped(text) // ends a pause or a disconnect: typing is an explicit request
        syncControls()
    }

    // MARK: session controls (the shade's tiles, the orb's menu, the menu bar and ⌥⌘M)

    /// Does what a control's press asks for. Each control passes the press its title promised when it was shown
    /// (`SessionControls.mutePress` and friends), so a press that arrives twice lands on the same state twice
    /// instead of flipping it back. Mute always mutes, even while the session is closed (the engine's toggle would
    /// read that press as reconnect; Connect does that here).
    func press(_ press: ControlPress) {
        guard let session else { return }
        switch press {
        case .mute(let on):
            _ = muteDebounce.accept() // ⌥⌘M right after this is the same press
            session.setMuted(on)
        case .pause(let on): if on { session.pause() } else { session.resume() }
        case .connect(let on):
            if on { session.reconnect() } else { session.disconnect() }
            if !on { activation(.reset) } // closed by you: no conversation to finish
        }
        syncControls()
    }

    /// ⌥⌘M is a toggle by nature: it presses whatever the Mute control offers now. A press delivered twice, or
    /// right after a Mute press elsewhere, counts once.
    func hotkeyMute() {
        guard muteDebounce.accept() else { return }
        syncControls()
        press(chat.controls.mutePress)
    }

    func stopSpeaking() {
        session?.stopSpeech(reason: "you pressed Stop")
        syncControls()
    }

    static func controls(of session: Realtime?) -> SessionControls {
        guard let session else { return SessionControls() }
        let link = SessionControls.link(open: session.status != .disconnected, dormant: session.dormant,
                                        disconnectedByUser: session.disconnectedByUser)
        return SessionControls(available: true, link: link, muted: session.muted, paused: session.paused,
                               speaking: session.audio.isSpeaking)
    }

    /// Copies the session's state to the controls: every frame, and right after a control is used.
    func syncControls() {
        let controls = Self.controls(of: session)
        if chat.controls != controls { chat.controls = controls }
    }

    /// The controls as menu entries, for the orb's menu and the menu bar: the state first (disabled), then each
    /// control under the title it has now.
    func controlChoices(syncing: Bool = true) -> [(title: String, enabled: Bool, action: () -> Void)] {
        if syncing { syncControls() } // not from a view's body: that would change what it is drawing
        let c = chat.controls
        return [
            ("Voice: \(c.state)", false, {}),
            (c.muteTitle, c.available, { [weak self] in self?.press(c.mutePress) }),
            (c.pauseTitle, c.available, { [weak self] in self?.press(c.pausePress) }),
            (SessionControls.stopTitle, c.canStopSpeaking, { [weak self] in self?.stopSpeaking() }),
            (c.connectTitle, c.available, { [weak self] in self?.press(c.connectPress) }),
        ]
    }

    // MARK: routing

    /// Asks the router which learned skill or harness this turn needs, over the registry's route options, without
    /// holding up the voice: the answer narrows the tools for the steps that follow, and `use_skill` covers anything
    /// it misses.
    /// Each of your turns: routed to a skill, and "that's all" ends the conversation.
    private func userSaid(_ text: String) {
        route(text)
        if DismissPhrase.matches(text) { activation(.dismiss) }
    }

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
        followAccent()
        if after.routeWithJev != before.routeWithJev || after.jevModel != before.jevModel { refreshRouter() }
        if after.activation != before.activation || after.activationKey != before.activationKey
            || after.followUpSeconds != before.followUpSeconds || after.wakePhrase != before.wakePhrase {
            applyActivation()
        }
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
            phone.screen = .settings
            return
        }
        guard let session else { return startSession() }
        if session.provider != provider {
            session.switchProvider(to: provider, key: key, voice: voice)
            applyActivation() // the cooldown depends on whether the new provider can hold a reply
        }
    }

    func title(ofSkill id: String) -> String {
        skills.first { $0.id == id }?.skill.title ?? harnesses.first { $0.id == id }?.title ?? id
    }

    // MARK: the human's own edits (each applies at once and is logged as theirs)

    /// Runs one human edit; what went wrong shows on the screen they're on.
    func edit(_ change: () throws -> Void) {
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

    /// How she listens: the human's own setting (it decides the bill), never proposable.
    func setActivation(_ mode: ActivationMode) {
        guard mode != settings.activation else { return }
        edit { try registry.setField("settings", "activation", .string(mode.rawValue)) }
    }

    func setActivationKey(_ key: ActivationKey) {
        guard key != settings.activationKey else { return }
        edit { try registry.setField("settings", "activationKey", .string(key.rawValue)) }
    }

    func setFollowUp(_ seconds: Double) {
        let seconds = min(max(seconds.rounded(), CompanionSettings.followUpRange.lowerBound),
                          CompanionSettings.followUpRange.upperBound)
        guard seconds != settings.followUpSeconds else { return }
        edit { try registry.setField("settings", "followUpSeconds", .number(seconds)) }
    }

    func setWakePhrase(_ text: String) {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, phrase != settings.wakePhrase else { return }
        edit { try registry.setField("settings", "wakePhrase", .string(phrase)) }
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

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Voice Companion")
        let menu = NSMenu()
        menu.autoenablesItems = false // the controls set their own (Stop speaking only while she speaks)
        // Rebuilt each time it opens, so the controls' titles and the state line are current.
        let rebuilder = MenuRebuilder { [weak self] menu in
            menu.removeAllItems()
            self?.statusMenuItems().forEach(menu.addItem)
        }
        menu.delegate = rebuilder
        menuRebuilder = rebuilder
        statusMenuItems().forEach(menu.addItem)
        item.menu = menu
        statusItem = item
    }

    func statusMenuItems() -> [NSMenuItem] {
        let shown = phone.expanded
        var items: [NSMenuItem] = [ClosureMenuItem(shown ? "Hide Phone" : "Show Phone") { [weak self] in self?.togglePhone() },
                                   .separator()]
        for control in controlChoices() {
            let item = ClosureMenuItem(control.title, control.action)
            item.isEnabled = control.enabled
            items.append(item)
        }
        items += [
            .separator(),
            ClosureMenuItem("Skills…") { [weak self] in self?.openPhone(.skills, activate: true) },
            ClosureMenuItem("Settings…", key: ",") { [weak self] in self?.openPhone(.settings, activate: true) },
            .separator(),
            ClosureMenuItem("Quit Voice Companion", key: "q") { [weak self] in self?.quit() },
        ]
        return items
    }
}

/// Lets a menu be rebuilt as it opens.
@MainActor final class MenuRebuilder: NSObject, NSMenuDelegate {
    private let rebuild: (NSMenu) -> Void

    init(_ rebuild: @escaping (NSMenu) -> Void) { self.rebuild = rebuild }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }
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
