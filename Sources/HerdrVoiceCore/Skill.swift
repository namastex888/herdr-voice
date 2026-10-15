import Foundation

/// One skillset the voice can use: a slice of one harness's actions and what it's for. Built-in skills cover each
/// harness; learned skills are procedures the user taught out loud, one JSON file each. Jev routes every turn to
/// the skill it needs by its `summary`.
public struct Skill: Codable, Sendable, Equatable, Identifiable {
    /// One step of a learned procedure: a harness action and its JSON-object arguments.
    public struct Step: Codable, Sendable, Equatable {
        public var action: String
        public var arguments: String

        public init(action: String, arguments: String = "{}") {
            self.action = action
            self.arguments = arguments
        }
    }

    public var id: String
    public var title: String
    /// What it's for, in one sentence: what Jev routes on, and the line the voice sees in the skill catalog.
    public var summary: String
    /// The harness whose actions it offers ("learned" for a taught procedure, whose steps may span harnesses).
    public var harness: String
    /// The harness actions it offers. A learned skill offers one tool instead, `toolName`, which runs `steps`.
    public var actions: [String]
    public var steps: [Step]
    public var learned: Bool

    public init(id: String, title: String, summary: String, harness: String, actions: [String] = [],
                steps: [Step] = [], learned: Bool = false) {
        self.id = id
        self.title = title
        self.summary = summary
        self.harness = harness
        self.actions = actions
        self.steps = steps
        self.learned = learned
    }

    /// The tool a learned skill runs by.
    public var toolName: String { "skill_" + id.replacingOccurrences(of: "-", with: "_") }

    /// An id from a spoken title: "Start my day!" → "start-my-day".
    public static func slug(_ title: String) -> String {
        let words = title.lowercased().split { !($0.isLetter || $0.isNumber) }
        return words.prefix(8).joined(separator: "-")
    }
}

public extension Skill {
    /// The skills that ship with the app. Each lists the actions it offers; a harness that isn't available (Herdr not
    /// installed, shell or AppleScript switched off) leaves its skills out.
    static let builtIn: [Skill] = [
        Skill(id: "mac-apps", title: "Apps and files",
              summary: "Open, list and quit Mac apps; open websites, files and folders.",
              harness: "mac", actions: ["open_app", "quit_app", "list_apps", "open_url", "open_path"]),
        Skill(id: "mac-system", title: "Mac settings",
              summary: "Volume and mute, dark mode, the clipboard, notifications, battery, and putting the display to sleep.",
              harness: "mac", actions: ["get_volume", "set_volume", "mute", "set_dark_mode", "read_clipboard",
                                        "write_clipboard", "notify", "battery", "sleep_display"]),
        Skill(id: "mac-shortcuts", title: "Shortcuts",
              summary: "List and run the user's Shortcuts automations by name.",
              harness: "mac", actions: ["list_shortcuts", "run_shortcut"]),
        Skill(id: "mac-applescript", title: "AppleScript",
              summary: "Control an app beyond the other skills with an AppleScript, after the user's spoken yes.",
              harness: "mac", actions: ["run_applescript"]),
        Skill(id: "herdr-agents", title: "Coding agents",
              summary: "Talk to the coding agents (Claude Code, Codex) in Herdr: list them, send work, read what they did, "
                  + "answer their prompts, start a new one.",
              harness: "herdr", actions: ["list_agents", "prompt_agent", "read_agent", "answer_agent", "agent_info",
                                          "rename_agent", "start_agent", "focus"]),
        Skill(id: "herdr-layout", title: "Herdr layout",
              summary: "Arrange Herdr: workspaces, tabs, git worktrees and panes; read or watch any pane.",
              harness: "herdr", actions: ["list_workspaces", "create_workspace", "rename_workspace", "close_workspace",
                                          "create_tab", "rename_tab", "close_tab", "list_worktrees", "create_worktree",
                                          "open_worktree", "remove_worktree", "focus", "list_panes", "read_pane",
                                          "watch_pane", "split_pane", "close_pane", "zoom_pane", "resize_pane",
                                          "swap_panes", "move_pane", "rename_pane", "pane_processes"]),
        Skill(id: "shell", title: "Shell",
              summary: "Run a shell command in a folder, after the user's spoken yes for that exact command.",
              harness: "shell", actions: ["run_shell"]),
    ]
}

/// Learned skills on disk, one JSON file per skill.
public struct SkillStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Voice Companion/skills`.
    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Voice Companion/skills", isDirectory: true)
    }

    /// Every readable learned skill, by title. A file that doesn't decode is skipped, not fatal.
    public func load() -> [Skill] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Skill.self, from: Data(contentsOf: $0)) }
            .filter(\.learned)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func save(_ skill: Skill) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(skill).write(to: file(skill.id), options: .atomic)
    }

    public func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: file(id))
    }

    private func file(_ id: String) -> URL {
        directory.appendingPathComponent(Skill.slug(id) + ".json")
    }
}
