import Foundation

/// A skill the human taught: a `skill.<id>` entry of the configuration tree, read as a value. It can carry a
/// procedure (`steps`, replayed as the tool `toolName`), a playbook (how to do the task, read out by `use_skill`), or
/// both. `needs` names the harnesses it uses; while one is missing the skill is inactive. The companion ships with
/// none.
public struct Skill: Codable, Sendable, Equatable, Identifiable {
    /// One step of a procedure: a harness action and its JSON-object arguments.
    public struct Step: Codable, Sendable, Hashable {
        public var action: String
        public var arguments: String

        public init(action: String, arguments: String = "{}") {
            self.action = action
            self.arguments = arguments
        }
    }

    /// Actions a skill may not contain: they always need a spoken yes, which a replayed step can't carry.
    public static let unrepeatable: Set<String> = ["run_shell", "run_in_pane", "run_applescript", "close_workspace",
                                                   "close_tab", "close_pane", "remove_worktree", "answer_agent"]
    public static let maxSteps = 20

    /// The slug after `skill.` in the entry id.
    public var id: String
    public var title: String
    /// What it's for, in one sentence: what routing matches on, and the line the voice sees in its catalog.
    public var summary: String
    /// Harness names (`mac`, `herdr`, `shell`) whose actions it uses.
    public var needs: [String]
    public var steps: [Step]
    public var playbook: String

    public init(id: String, title: String, summary: String, needs: [String] = [], steps: [Step] = [],
                playbook: String = "") {
        self.id = id
        self.title = title
        self.summary = summary
        self.needs = needs
        self.steps = steps
        self.playbook = playbook
    }

    public static let entryPrefix = "skill."

    public var entryID: String { Self.entryPrefix + id }

    /// The tool its procedure runs by.
    public var toolName: String { "skill_" + id.replacingOccurrences(of: "-", with: "_") }

    /// An id from a spoken title: "Start my day!" → "start-my-day", "Café run" → "cafe-run". ASCII and at most 50
    /// characters, so `toolName` stays a valid tool name on every provider.
    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let words = folded.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        var slug = words.prefix(8).joined(separator: "-")
        if slug.count > 50 {
            slug = String(slug.prefix(50))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug
    }

    // MARK: tree entries

    public var config: [String: JSONValue] {
        [
            "title": .string(title), "summary": .string(summary), "needs": .array(needs.map(JSONValue.string)),
            "steps": .array(steps.map { .object(["action": .string($0.action), "arguments": .string($0.arguments)]) }),
            "playbook": .string(playbook),
        ]
    }

    public var entry: ConfigEntry { ConfigEntry(id: entryID, kind: .skill, config: config) }

    /// Reads a `skill.<id>` entry. Throws when its config isn't shaped like a skill.
    public init(entry: ConfigEntry) throws {
        guard entry.kind == .skill, entry.id.hasPrefix(Self.entryPrefix) else {
            throw ComponentError("\(entry.id) isn't a skill entry")
        }
        try self.init(id: String(entry.id.dropFirst(Self.entryPrefix.count)), config: entry.config)
    }

    public init(id: String, config: [String: JSONValue]) throws {
        func text(_ key: String, required: Bool) throws -> String {
            switch config[key] {
            case .string(let value)?: return value
            case nil, .null?: if !required { return "" }
            default: break
            }
            throw ComponentError("a skill's \(key) must be text")
        }
        let title = try text("title", required: true)
        let summary = try text("summary", required: false)
        let playbook = try text("playbook", required: false)
        var needs: [String] = []
        if let raw = config["needs"], !raw.isNull {
            guard let items = raw.array, items.allSatisfy({ $0.string != nil }) else {
                throw ComponentError("a skill's needs must be a list of harness names")
            }
            needs = items.compactMap(\.string)
        }
        var steps: [Step] = []
        if let raw = config["steps"], !raw.isNull {
            guard let items = raw.array else { throw ComponentError("a skill's steps must be a list") }
            for (index, item) in items.enumerated() {
                guard let action = item.object?["action"]?.string, !action.isEmpty else {
                    throw ComponentError("step \(index + 1) needs an action")
                }
                let arguments: String
                switch item.object?["arguments"] {
                case nil, .null?: arguments = "{}"
                case .string(let value)?: arguments = value
                case .object(let value)?: arguments = JSONValue.object(value).canonical
                default: throw ComponentError("step \(index + 1)'s arguments must be an object")
                }
                steps.append(Step(action: action, arguments: arguments))
            }
        }
        self.init(id: id, title: title, summary: summary, needs: needs, steps: steps, playbook: playbook)
    }

    /// A well-formed skill: a title, a normalized id, 1–20 steps or a playbook (or both), and steps that are actions
    /// `offered` (by the harnesses it may use), none of which always needs a spoken yes, each with object arguments.
    public func validate(offered: (String) -> Bool) throws {
        guard !id.isEmpty, Self.slug(id) == id else { throw ComponentError("a skill's id must be a slug like start-my-day") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComponentError("a skill needs a title")
        }
        guard steps.count <= Self.maxSteps else { throw ComponentError("a skill has at most \(Self.maxSteps) steps") }
        guard !steps.isEmpty || !playbook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComponentError("a skill needs 1 to \(Self.maxSteps) steps, a playbook, or both")
        }
        for (index, step) in steps.enumerated() {
            guard !Self.unrepeatable.contains(step.action) else {
                throw ComponentError("step \(index + 1), \(step.action), always needs a spoken yes, so a skill can't repeat it")
            }
            guard offered(step.action) else { throw ComponentError("step \(index + 1): no tool called \(step.action)") }
            guard let arguments = try? JSONSerialization.jsonObject(with: Data(step.arguments.utf8)) as? [String: Any] else {
                throw ComponentError("step \(index + 1)'s arguments must be a JSON object")
            }
            guard arguments["confirmed"] == nil else {
                throw ComponentError("step \(index + 1) can't carry a confirmation; a yes is only ever given live")
            }
        }
    }
}

/// Why an entry failed or a proposal was refused, in words the voice can pass on.
public struct ComponentError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
