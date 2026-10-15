import Foundation

/// A change the assistant asks to make to itself: operations on the configuration tree. Applies only after the
/// human's own yes (see `SkillRegistry`).
public struct Proposal: Codable, Sendable, Hashable {
    public struct Change: Codable, Sendable, Hashable {
        public enum Op: String, Codable, Sendable, CaseIterable {
            /// A field: `identity.personality`, `settings.voice`, `skill.start-my-day.summary`.
            case set
            /// An array item: `memory.facts`.
            case append, removeValue
            /// A whole entry: `skill.start-my-day`, with its config as the value.
            case addEntry, removeEntry
        }

        public var op: Op
        public var path: String
        public var value: JSONValue?

        public init(op: Op, path: String, value: JSONValue? = nil) {
            self.op = op
            self.path = path
            self.value = value
        }

        /// `identity.personality` → (`identity`, `personality`); `skill.start-my-day.title` → (`skill.start-my-day`,
        /// `title`). Configs are flat, so the key is the last segment.
        var field: (entry: String, key: String)? {
            guard let dot = path.lastIndex(of: "."), dot != path.startIndex, path.index(after: dot) != path.endIndex else {
                return nil
            }
            return (String(path[..<dot]), String(path[path.index(after: dot)...]))
        }
    }

    public var summary: String
    public var changes: [Change]

    public init(summary: String, changes: [Change]) {
        self.summary = summary
        self.changes = changes
    }

    /// The tool arguments `propose_change` takes: `{"summary": "...", "changes": [{"op", "path", "value"}]}`.
    public init(arguments args: [String: Any]) throws {
        let summary = (args["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw ComponentError("a proposal needs a one-sentence summary") }
        guard let raw = args["changes"] as? [Any], !raw.isEmpty else {
            throw ComponentError("a proposal needs at least one change")
        }
        var changes: [Change] = []
        for item in raw {
            guard let change = item as? [String: Any], let opName = change["op"] as? String,
                  let op = Change.Op(rawValue: opName), let path = change["path"] as? String else {
                throw ComponentError("each change needs an op (" + Change.Op.allCases.map(\.rawValue)
                    .joined(separator: ", ") + ") and a path")
            }
            var value: JSONValue?
            if let raw = change["value"] {
                guard let parsed = JSONValue(any: raw) else { throw ComponentError("\(path): the value isn't JSON") }
                value = parsed
            }
            changes.append(Change(op: op, path: path, value: value))
        }
        self.init(summary: summary, changes: changes)
    }

    /// The exact proposal, as the gate arms it: a yes counts only for these bytes.
    public var gateKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return "proposal:" + ((try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? summary)
    }
}

/// Which paths the assistant may propose (§1). Everything else, above all the harness entries, every `disabled`,
/// `settings.provider` and the confirmation rules, is the human's, changed only in the app's own UI.
public enum Governance {
    public static let identityKeys: Set<String> = ["name", "role", "personality", "instructions"]
    public static let settingsKeys: Set<String> = ["voice", "routeWithJev", "jevModel"]
    public static let skillKeys: Set<String> = ["title", "summary", "needs", "steps", "playbook"]

    /// Refuses a change to a path that isn't proposable, or a value of the wrong type.
    public static func check(_ change: Proposal.Change) throws {
        let humanOwned = ComponentError("\(change.path) is the human's to change, in the app; you can't propose it")
        if change.path.hasPrefix("harness.") || change.path == "harness" || change.path.hasSuffix(".disabled")
            || change.path == "settings.provider" {
            throw humanOwned
        }
        switch change.op {
        case .addEntry, .removeEntry:
            guard change.path.hasPrefix(Skill.entryPrefix), !change.path.dropFirst(Skill.entryPrefix.count).contains(".") else {
                throw ComponentError("only skill entries can be added or removed; \(change.path) can't")
            }
            let id = String(change.path.dropFirst(Skill.entryPrefix.count))
            guard !id.isEmpty, Skill.slug(id) == id else {
                throw ComponentError("\(change.path): a skill's id is a slug like skill.start-my-day")
            }
            if change.op == .addEntry, change.value?.object == nil {
                throw ComponentError("\(change.path): addEntry needs the skill's config as an object")
            }
        case .set:
            guard let (entry, key) = change.field, let value = change.value else {
                throw ComponentError("\(change.path): set needs an entry.key path and a value")
            }
            switch entry {
            case "identity":
                guard identityKeys.contains(key) else { throw ComponentError("\(change.path) can't be changed") }
                guard value.string != nil else { throw ComponentError("\(change.path) must be text") }
            case "memory":
                guard key == "facts" else { throw ComponentError("\(change.path) can't be changed") }
                guard value.array?.allSatisfy({ $0.string != nil }) == true else {
                    throw ComponentError("memory.facts must be a list of sentences")
                }
            case "settings":
                guard settingsKeys.contains(key) else { throw ComponentError("\(change.path) can't be changed") }
                switch key {
                case "routeWithJev": guard value.bool != nil else { throw ComponentError("\(change.path) must be true or false") }
                case "voice": guard value.string != nil || value.isNull else { throw ComponentError("\(change.path) must be text") }
                default: guard !(value.string ?? "").isEmpty else { throw ComponentError("\(change.path) must be text") }
                }
            default:
                guard entry.hasPrefix(Skill.entryPrefix), skillKeys.contains(key) else {
                    throw ComponentError("\(change.path) can't be changed")
                }
            }
        case .append, .removeValue:
            guard change.path == "memory.facts" else {
                throw ComponentError("\(change.op.rawValue) works on memory.facts only")
            }
            guard let fact = change.value?.string, !fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ComponentError("a memory fact is one sentence of text")
            }
        }
    }
}

extension ConfigTree {
    /// The tree with `proposal`'s operations applied in order. Throws when one doesn't fit the tree (a missing
    /// entry, a skill that already exists, a fact that isn't there). Doesn't check governance.
    public func applying(_ proposal: Proposal) throws -> ConfigTree {
        var tree = self
        for change in proposal.changes {
            switch change.op {
            case .addEntry:
                guard tree[change.path] == nil else {
                    throw ComponentError("\(change.path) already exists; remove it first or set its fields")
                }
                let id = String(change.path.dropFirst(Skill.entryPrefix.count))
                let skill = try Skill(id: id, config: change.value?.object ?? [:])
                tree.entries.append(skill.entry)
            case .removeEntry:
                guard tree[change.path] != nil else { throw ComponentError("there is no \(change.path)") }
                tree[change.path] = nil
            case .set, .append, .removeValue:
                guard let (id, key) = change.field, var entry = tree[id] else {
                    throw ComponentError("there is no entry for \(change.path)")
                }
                let value = change.value ?? .null
                switch change.op {
                case .set:
                    entry.config[key] = value
                case .append:
                    entry.config[key] = .array((entry.config[key]?.array ?? []) + [value])
                default:
                    let items = entry.config[key]?.array ?? []
                    guard items.contains(value) else { throw ComponentError("\(change.path) has no \(value.canonical)") }
                    entry.config[key] = .array(items.filter { $0 != value })
                }
                if entry.kind == .skill { // normalized, so step arguments are always JSON text
                    let id = String(entry.id.dropFirst(Skill.entryPrefix.count))
                    entry.config = try Skill(id: id, config: entry.config).config
                }
                tree[id] = entry
            }
        }
        return tree
    }

    /// Ids whose entry differs between the two trees (added, changed or removed).
    public func changedIDs(to other: ConfigTree) -> [String] {
        let ids = (entries + other.entries).map(\.id)
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted && self[$0] != other[$0] }
    }
}

/// One applied change, kept so it can be listed and reverted.
public struct ChangeRecord: Codable, Sendable, Hashable, Identifiable {
    public enum Author: String, Codable, Sendable {
        case assistant, user
    }

    /// Short, so the voice can say it ("c3").
    public let id: String
    public let summary: String
    public let before: ConfigTree
    public let after: ConfigTree
    public let time: Date
    public let by: Author
    /// The change this one reverted, if it is a revert.
    public let revertOf: String?

    public init(id: String, summary: String, before: ConfigTree, after: ConfigTree, time: Date, by: Author,
                revertOf: String? = nil) {
        self.id = id
        self.summary = summary
        self.before = before
        self.after = after
        self.time = time
        self.by = by
        self.revertOf = revertOf
    }

    /// `current` with each entry this change touched put back as it was before it. `keepHumanOwned` leaves the
    /// human's parts (harness entries, every `disabled`, `settings.provider`) as they are now, so the assistant's
    /// revert of it only ever touches what it may propose.
    public func revertTarget(from current: ConfigTree, keepHumanOwned: Bool) -> ConfigTree {
        var target = current
        for id in before.changedIDs(to: after) {
            guard var restored = before[id] else {
                if !(keepHumanOwned && current[id]?.kind == .harness) { target[id] = nil }
                continue
            }
            if keepHumanOwned {
                if restored.kind == .harness { continue }
                restored.disabled = current[id]?.disabled ?? false
                if restored.kind == .settings { restored.config["provider"] = current[id]?.config["provider"] }
            }
            target[id] = restored
        }
        return target
    }
}

extension Proposal {
    /// The operations that turn `current` into `target`: skills added, removed or replaced whole; identity, memory
    /// and settings set field by field.
    static func between(_ current: ConfigTree, _ target: ConfigTree, summary: String) -> Proposal {
        var changes: [Change] = []
        for id in current.changedIDs(to: target) {
            let now = current[id], then = target[id]
            if now?.kind == .skill || then?.kind == .skill || now == nil || then == nil {
                if now != nil { changes.append(Change(op: .removeEntry, path: id)) }
                if let then { changes.append(Change(op: .addEntry, path: id, value: .object(then.config))) }
                continue
            }
            guard let now, let then else { continue }
            if now.disabled != then.disabled { changes.append(Change(op: .set, path: id + ".disabled", value: .bool(then.disabled))) }
            for key in Set(now.config.keys).union(then.config.keys).sorted() where now.config[key] != then.config[key] {
                changes.append(Change(op: .set, path: id + "." + key, value: then.config[key] ?? .null))
            }
        }
        return Proposal(summary: summary, changes: changes)
    }

    /// What the change does, in plain words: the question the human says yes to is built from the operations
    /// themselves, never only from the assistant's own summary.
    func spoken(in tree: ConfigTree) -> String {
        changes.map { change in
            switch change.op {
            case .addEntry:
                let title = change.value?.object?["title"]?.string ?? change.path
                let steps = (change.value?.object?["steps"]?.array ?? []).compactMap { $0.object?["action"]?.string }
                let notes = (change.value?.object?["playbook"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var what = "learn a skill called \(title)"
                if !steps.isEmpty { what += " that runs " + steps.joined(separator: ", ") }
                // The notes become the voice's instructions when the skill loads, so the human approves their text, not a label.
                if !notes.isEmpty {
                    let quoted = notes.count > 240 ? String(notes.prefix(240)) + "…" : notes
                    what += (steps.isEmpty ? " with these how-to notes: " : ", with these how-to notes: ") + "\"\(quoted)\""
                }
                return what
            case .removeEntry:
                return "forget the skill \(tree[change.path]?.config["title"]?.string ?? change.path)"
            case .append:
                return "remember that \(change.value?.string ?? "")"
            case .removeValue:
                return "forget that \(change.value?.string ?? "")"
            case .set:
                let value = change.value?.string ?? change.value?.canonical ?? "nothing"
                return "set \(change.path) to \(value)"
            }
        }.joined(separator: "; ")
    }
}

/// How the companion grows, kept beside the tree (never in it) and shown in the app.
public struct GrowthMetrics: Codable, Sendable, Hashable {
    /// Skills added by an applied proposal.
    public var skillsTaught = 0
    /// Procedure runs, and the runs that stopped at a step that didn't go through.
    public var replays = 0
    public var replayFailures = 0
    /// Proposals the human said yes to (reverts not counted), and reverts applied.
    public var proposalsApplied = 0
    public var reverted = 0

    public init() {}
}
