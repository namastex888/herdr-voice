import Foundation

/// One surface the companion can drive: Herdr, the Mac, a shell. It offers actions as tool definitions and runs
/// them. A `harness` entry of the configuration tree runs one (see `HarnessFactory`); learned skills name the
/// harnesses they need.
public protocol Harness: Sendable {
    /// Stable id that skills name ("herdr", "mac", "shell").
    var id: String { get }
    var title: String { get }
    /// What its controls are for, in one sentence: routing matches on it and the voice reads it in its catalog.
    var summary: String { get }
    /// Whether it can work on this Mac right now (Herdr: the CLI is installed; shell: switched on).
    var isAvailable: Bool { get }
    /// Every action it offers, as tool definitions.
    var actions: ToolList { get }
    /// Runs one action, blocking: called off the main thread. Actions that change something the user didn't just
    /// ask for, or that can't be undone, ask for a spoken yes through the shared `ConfirmGate`, as Herdr's do.
    func call(_ name: String, arguments: String, userInitiated: Bool) -> HerdrTools.Outcome
}

public extension Harness {
    var actionNames: [String] { actions.names }
    var summary: String { "Controls for \(title): " + actionNames.joined(separator: ", ") + "." }
}

/// Makes the harness a `harness` entry names, from that entry's config. The companion uses `standard`; tests inject
/// fakes. Throwing marks the entry failed.
public struct HarnessFactory: Sendable {
    public let make: @Sendable (_ name: String, _ config: [String: JSONValue]) throws -> any Harness

    public init(_ make: @escaping @Sendable (_ name: String, _ config: [String: JSONValue]) throws -> any Harness) {
        self.make = make
    }

    /// `mac` (`appleScript` in its config turns on run_applescript), `herdr`, `shell` (on unless its entry is
    /// disabled, which the human owns).
    public static let standard = HarnessFactory { name, config in
        switch name {
        case "mac":
            guard config["appleScript"].map({ $0.bool != nil || $0.isNull }) ?? true else {
                throw ComponentError("the Mac harness's appleScript must be true or false")
            }
            return MacHarness(allowAppleScript: config["appleScript"]?.bool ?? false)
        case "herdr": return HerdrHarness()
        case "shell": return ShellHarness(enabled: true)
        default: throw ComponentError("there is no harness called \(name)")
        }
    }
}

/// Herdr's panes, agents, workspaces, tabs and worktrees, through the `herdr` CLI.
public struct HerdrHarness: Harness {
    public init() {}

    public var id: String { "herdr" }
    public var title: String { "Herdr" }
    public var summary: String {
        "Coding agents (Claude Code, Codex) in Herdr: list them, send them work, read and answer them, start new ones; "
            + "workspaces, tabs, worktrees and panes."
    }
    public var isAvailable: Bool { HerdrTools.isInstalled() }
    public var actions: ToolList { ToolList(HerdrTools.schemas(includeShell: false)) }

    public func call(_ name: String, arguments: String, userInitiated: Bool) -> HerdrTools.Outcome {
        HerdrTools.call(name, arguments: arguments, userInitiated: userInitiated)
    }
}

/// `run_shell`: zsh commands, each needing a spoken yes for that exact command. Off unless switched on.
public struct ShellHarness: Harness {
    private let enabled: Bool

    public init(enabled: Bool = HerdrTools.shellEnabled) {
        self.enabled = enabled
    }

    public var id: String { "shell" }
    public var title: String { "Shell" }
    public var summary: String { "Run a shell command in a folder, after the user's spoken yes for that exact command." }
    public var isAvailable: Bool { enabled }
    public var actions: ToolList { ToolList([HerdrTools.shellSchema]) }

    public func call(_ name: String, arguments: String, userInitiated: Bool) -> HerdrTools.Outcome {
        guard enabled else { return HerdrTools.Outcome(output: "error: the shell is switched off", watch: nil) }
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        return HerdrTools.Outcome(output: HerdrTools.runShell(args["command"] as? String ?? "", cwd: args["cwd"] as? String,
                                                              confirmed: args["confirmed"] as? Bool ?? false, .shared),
                                  watch: nil)
    }
}

public extension HerdrTools {
    /// Whether a `herdr` binary can be found: Herdr's own (HERDR_BIN_PATH), or one on PATH.
    static func isInstalled(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let path = env["HERDR_BIN_PATH"], path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
            return true
        }
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.contains { FileManager.default.isExecutableFile(atPath: $0 + "/herdr") }
    }
}
