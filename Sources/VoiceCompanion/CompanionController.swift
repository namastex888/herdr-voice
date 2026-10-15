import AppKit
import HerdrVoiceCore
import VoiceEngine

/// Owns the companion: the skill registry (the master harness), routing, the voice session, the chat panel, the orb
/// and the menu bar item. Every user turn, spoken or typed, is routed to a skill while the voice answers; the
/// session then offers that skill's tools from the next step on.
@MainActor final class CompanionController: ObservableObject {
    struct ActionInfo: Hashable {
        let name: String
        let description: String
    }

    struct HarnessInfo: Identifiable {
        let id: String
        let title: String
        let available: Bool
        let unavailableReason: String
        let actions: [ActionInfo]
    }

    /// Turns kept as context for routing.
    static let routingContext = 6

    let settings: CompanionSettings
    let chat = ChatModel()
    let registry: SkillRegistry
    let harnesses: [HarnessInfo]
    @Published var tab: CompanionTab = .chat
    @Published private(set) var skills: [Skill] = []
    private var router: any SkillRouter
    private(set) var session: Realtime?
    private var window: ChatWindow?
    private var orb: Orb?
    private var statusItem: NSStatusItem?
    private var recentTurns: [String] = []

    init(settings: CompanionSettings = CompanionSettings(),
         store: SkillStore? = SkillStore(directory: SkillStore.defaultDirectory)) {
        self.settings = settings
        let all: [any Harness] = [MacHarness(allowAppleScript: settings.allowAppleScript), HerdrHarness(),
                                  ShellHarness(enabled: settings.allowShell)]
        registry = SkillRegistry(harnesses: all, store: store)
        router = CompanionRouter(jev: settings.jevRouter)
        harnesses = all.map { harness in
            HarnessInfo(id: harness.id, title: harness.title, available: harness.isAvailable,
                        unavailableReason: Self.unavailableReason(harness.id),
                        actions: harness.actions.definitions.map {
                            ActionInfo(name: $0["name"] as? String ?? "", description: $0["description"] as? String ?? "")
                        })
        }
        chat.provider = settings.provider
        registry.onActiveChange { [weak self] ids in
            DispatchQueue.main.async { self?.activeSkillsChanged(ids) }
        }
        // The skills in play before anything is routed; the last one activated comes first.
        for id in ["mac-system", "mac-apps"] + (HerdrTools.isInstalled() ? ["herdr-agents"] : []) {
            registry.activate(id)
        }
        skills = registry.skills
        chat.activeSkills = registry.active
    }

    private static func unavailableReason(_ harness: String) -> String {
        switch harness {
        case "herdr": "Herdr isn't installed here (no herdr command found), so its skills are off."
        case "shell": "Off. Turn on shell commands in Settings to use it."
        default: "Not available."
        }
    }

    // MARK: lifecycle

    func start() {
        let window = ChatWindow(content: CompanionView(controller: self, chat: chat, settings: settings))
        self.window = window
        installStatusItem()
        installOrb()
        Hotkey.registerMute { [weak self] in self?.toggleMute() }
        startSession()
        window.show()
    }

    /// Opens the voice session for the chosen provider, or points the user at Settings when it has no key yet.
    private func startSession() {
        let provider = settings.provider
        guard let key = settings.key(for: provider) else {
            chat.note("Add a \(provider.menuTitle) API key in Settings to start talking.")
            tab = .settings
            return
        }
        let session = Realtime(provider: provider, key: key, voice: provider.defaultVoice, host: registry,
                               instructions: CompanionVoice.instructions(catalog: registry.catalog,
                                                                         herdr: HerdrTools.isInstalled()),
                               greeting: CompanionVoice.greeting)
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
        chat.provider = provider
    }

    func quit() {
        session?.shutdown()
        // A moment for the WebSocket close frame to go out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    /// Relaunches the app (settings that change which tools exist apply at launch).
    func restart() {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", bundle.path]
            try? relaunch.run()
        }
        quit()
    }

    // MARK: talking and typing

    func send(_ text: String) {
        guard let session else {
            chat.append(.you(text))
            chat.note("Add a \(settings.provider.menuTitle) API key in Settings first.")
            tab = .settings
            return
        }
        session.sendTyped(text)
    }

    func toggleMute() {
        session?.toggleMute()
        chat.muted = session?.muted ?? false
    }

    func switchProvider(to provider: Provider) {
        settings.provider = provider
        chat.provider = provider
        guard let key = settings.key(for: provider) else {
            chat.note("\(provider.menuTitle) has no API key yet; add one below.")
            tab = .settings
            return
        }
        guard let session else { return startSession() }
        session.switchProvider(to: provider, key: key, voice: provider.defaultVoice)
    }

    // MARK: routing

    /// Asks the router which skill this turn needs, without holding up the voice: the answer narrows the tools
    /// for the steps that follow, and `use_skill` covers anything it misses.
    private func route(_ text: String) {
        recentTurns = Array((recentTurns + [text]).suffix(Self.routingContext))
        let router = router, skills = registry.skills, recent = Array(recentTurns.dropLast())
        Task { @MainActor [weak self] in
            guard let decision = await router.route(text, recent: recent, skills: skills), let self else { return }
            self.chat.lastRoute = decision
            if decision.skill != RouteDecision.chat { self.registry.activate(decision.skill) }
        }
    }

    func refreshRouter() {
        router = CompanionRouter(jev: settings.jevRouter)
    }

    private func activeSkillsChanged(_ ids: [String]) {
        chat.activeSkills = ids
        skills = registry.skills
        session?.setTools(registry.activeTools)
    }

    func title(ofSkill id: String) -> String {
        skills.first { $0.id == id }?.title ?? id
    }

    func deleteLearned(_ id: String) {
        do {
            try registry.removeLearned(id)
        } catch {
            chat.note("Couldn't delete that skill: \(error.localizedDescription)")
        }
        activeSkillsChanged(registry.active)
    }

    func openSkillsFolder() {
        let folder = SkillStore.defaultDirectory
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
        choices += CompanionSettings.providers.map { provider in
            Orb.MenuChoice(title: provider.menuTitle, checked: provider == settings.provider,
                           enabled: settings.hasKey(provider)) { [weak self] in self?.switchProvider(to: provider) }
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
