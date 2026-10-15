import Foundation

/// Tool definitions as the wires send them: JSON-schema dictionaries in the Realtime function format
/// (`type`, `name`, `description`, `parameters`). Never mutated once made, which is what makes sharing them safe.
public struct ToolList: @unchecked Sendable {
    public let definitions: [[String: Any]]

    public init(_ definitions: [[String: Any]]) {
        self.definitions = definitions
    }

    public var names: [String] { definitions.compactMap { $0["name"] as? String } }
}

/// What a voice session runs tools through. The Herdr plugin's host offers every Herdr tool; the companion's
/// `SkillRegistry` offers the tools of the skills in play and routes each call to the harness that owns it.
public protocol ToolHost: Sendable {
    /// The tools a session starts with, and keeps on providers that can't change tools mid-session.
    var tools: ToolList { get }
    /// Runs one call, blocking: the session calls it off the main thread. `userInitiated` is false when the model is
    /// acting on a report rather than on the developer's words, so risky actions then need a spoken yes.
    func call(_ name: String, arguments: String, userInitiated: Bool) -> HerdrTools.Outcome
    /// Waits in the background until agent `target` settles; `done` gets the report for the voice.
    func settle(_ target: String, done: @escaping @Sendable (String) -> Void)
    /// Waits in the background for a pane to show something; `done` gets the report for the voice.
    func watchPane(_ watch: HerdrTools.PaneWatch, done: @escaping @Sendable (String) -> Void)
}

/// The Herdr plugin's host: every Herdr tool, run through `herdr`.
public struct HerdrToolHost: ToolHost {
    public init() {}

    public var tools: ToolList { ToolList(HerdrTools.schemas) }

    public func call(_ name: String, arguments: String, userInitiated: Bool) -> HerdrTools.Outcome {
        HerdrTools.call(name, arguments: arguments, userInitiated: userInitiated)
    }

    public func settle(_ target: String, done: @escaping @Sendable (String) -> Void) {
        HerdrTools.settle(target, done: done)
    }

    public func watchPane(_ watch: HerdrTools.PaneWatch, done: @escaping @Sendable (String) -> Void) {
        HerdrTools.watchPane(watch, done: done)
    }
}
