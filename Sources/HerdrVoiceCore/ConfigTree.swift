import Foundation

/// A JSON value with equality: what entry configs and proposal values are made of. Trees compare by value, which is
/// what reload detection, the confluence checks and revert rely on.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// From what `JSONSerialization` returns (tool-call arguments). Booleans are told apart from numbers.
    public init?(any value: Any) {
        switch value {
        case is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let string as String: self = .string(string)
        case let array as [Any]:
            var items: [JSONValue] = []
            for item in array {
                guard let value = JSONValue(any: item) else { return nil }
                items.append(value)
            }
            self = .array(items)
        case let object as [String: Any]:
            var fields: [String: JSONValue] = [:]
            for (key, item) in object {
                guard let value = JSONValue(any: item) else { return nil }
                fields[key] = value
            }
            self = .object(fields)
        default: return nil
        }
    }

    /// What `JSONSerialization` takes.
    public var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let value): value.map(\.any)
        case .object(let value): value.mapValues(\.any)
        }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var isNull: Bool { self == .null }

    /// Compact JSON with sorted keys: a stable text for logs, gate keys and step arguments.
    public var canonical: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}

/// What kind of component an entry is. Open-ended so a tree written by a newer build still loads: an unknown kind
/// is a *failed* entry, not an unreadable file.
public struct ComponentKind: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let harness = ComponentKind(rawValue: "harness")
    public static let identity = ComponentKind(rawValue: "identity")
    public static let memory = ComponentKind(rawValue: "memory")
    public static let settings = ComponentKind(rawValue: "settings")
    public static let skill = ComponentKind(rawValue: "skill")
}

/// One entry of the configuration tree: what one component runs with.
public struct ConfigEntry: Codable, Sendable, Hashable {
    public var id: String
    public var kind: ComponentKind
    public var config: [String: JSONValue]
    /// Human-owned: only the app's own UI changes it.
    public var disabled: Bool

    public init(id: String, kind: ComponentKind, config: [String: JSONValue] = [:], disabled: Bool = false) {
        self.id = id
        self.kind = kind
        self.config = config
        self.disabled = disabled
    }

    private enum CodingKeys: String, CodingKey { case id, kind, config, disabled }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(ComponentKind.self, forKey: .kind)
        config = try container.decodeIfPresent([String: JSONValue].self, forKey: .config) ?? [:]
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(config, forKey: .config)
        if disabled { try container.encode(true, forKey: .disabled) }
    }
}

/// The authoritative record of what runs (`config.json`). The host's state depends only on it.
public struct ConfigTree: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int
    public var entries: [ConfigEntry]

    public init(version: Int = ConfigTree.currentVersion, entries: [ConfigEntry]) {
        self.version = version
        self.entries = entries
    }

    public subscript(id: String) -> ConfigEntry? {
        get { entries.first { $0.id == id } }
        set {
            if let index = entries.firstIndex(where: { $0.id == id }) {
                if let newValue { entries[index] = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append(newValue)
            }
        }
    }

    public var skillEntries: [ConfigEntry] { entries.filter { $0.kind == .skill } }
    public var harnessEntries: [ConfigEntry] { entries.filter { $0.kind == .harness } }

    // MARK: factory state

    public static let defaultIdentity: [String: JSONValue] = [
        "name": .string("Companion"),
        "role": .string("a newly hired personal assistant on the user's Mac"),
        "personality": .string("eager to help, humble about what you don't know yet, and concise"),
        "instructions": .string(""),
    ]
    public static let defaultMemory: [String: JSONValue] = ["facts": .array([])]
    public static let defaultSettings: [String: JSONValue] = [
        "voice": .null, "routeWithJev": .bool(true), "jevModel": .string(JevRouter.defaultModel), "provider": .null,
    ]

    /// The new hire: its harnesses (the shell off), identity, empty memory, default settings, and no skills.
    public static let factory = ConfigTree(entries: [
        ConfigEntry(id: "harness.mac", kind: .harness, config: ["harness": .string("mac"), "appleScript": .bool(false)]),
        ConfigEntry(id: "harness.herdr", kind: .harness, config: ["harness": .string("herdr")]),
        ConfigEntry(id: "harness.shell", kind: .harness, config: ["harness": .string("shell")], disabled: true),
        ConfigEntry(id: "identity", kind: .identity, config: defaultIdentity),
        ConfigEntry(id: "memory", kind: .memory, config: defaultMemory),
        ConfigEntry(id: "settings", kind: .settings, config: defaultSettings),
    ])

    /// "Reset to new hire": the factory identity, memory, settings and no skills, keeping what the human owns
    /// (the harness entries and the provider).
    public func resetToNewHire() -> ConfigTree {
        var reset = ConfigTree(version: version, entries: harnessEntries)
        reset.entries += Self.factory.entries.filter { $0.kind != .harness }
        if var settings = reset["settings"], let provider = self["settings"]?.config["provider"] {
            settings.config["provider"] = provider
            reset["settings"] = settings
        }
        return reset
    }
}

/// Where the companion keeps itself: `config.json` (the tree), `changes.json` (the change log) and `growth.json`
/// (growth metrics, kept out of the tree so they never take part in reconcile).
public struct CompanionStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Voice Companion`.
    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Voice Companion", isDirectory: true)
    }

    public var configFile: URL { directory.appendingPathComponent("config.json") }
    public var changesFile: URL { directory.appendingPathComponent("changes.json") }
    public var metricsFile: URL { directory.appendingPathComponent("growth.json") }
    /// 0.1.0 kept each learned skill here, one JSON file each. Read once by the migration and left in place.
    public var legacySkillsDirectory: URL { directory.appendingPathComponent("skills", isDirectory: true) }

    /// The tree on disk. With no `config.json`, it is built from 0.1.0's state (or is the factory tree) and written.
    /// An unreadable `config.json` is moved aside to `config.unreadable.json` rather than overwritten.
    public func loadTree(legacyDefaults: UserDefaults?, factory: HarnessFactory = .standard) -> ConfigTree {
        if let data = try? Data(contentsOf: configFile) {
            if let tree = try? JSONDecoder().decode(ConfigTree.self, from: data) { return tree }
            let aside = directory.appendingPathComponent("config.unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: configFile, to: aside)
        }
        let tree = ConfigMigration.from010(defaults: legacyDefaults, skillsDirectory: legacySkillsDirectory,
                                           factory: factory)
        try? save(tree)
        return tree
    }

    public func save(_ tree: ConfigTree) throws {
        try write(tree, to: configFile)
    }

    public func loadChanges() -> [ChangeRecord] {
        (try? Data(contentsOf: changesFile)).flatMap { try? Self.decoder.decode([ChangeRecord].self, from: $0) } ?? []
    }

    public func saveChanges(_ changes: [ChangeRecord]) throws {
        try write(changes, to: changesFile)
    }

    public func loadMetrics() -> GrowthMetrics {
        (try? Data(contentsOf: metricsFile)).flatMap { try? JSONDecoder().decode(GrowthMetrics.self, from: $0) }
            ?? GrowthMetrics()
    }

    public func saveMetrics(_ metrics: GrowthMetrics) throws {
        try write(metrics, to: metricsFile)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func write(_ value: some Encodable, to file: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: file, options: .atomic)
    }
}

/// Builds the tree from Voice Companion 0.1.0's state.
public enum ConfigMigration {
    /// 0.1.0's learned skill file.
    struct LegacySkill: Decodable {
        struct Step: Decodable {
            var action: String
            var arguments: String?
        }

        var id: String
        var title: String
        var summary: String
        var steps: [Step]?
        var learned: Bool?
    }

    /// UserDefaults `provider`, `allowAppleScript`, `allowShell`, `routeWithJev`, `jevModel`, and every learned skill
    /// in `skillsDirectory`. A skill's `needs` are the harnesses whose actions its steps use. Files that don't decode
    /// are skipped. With nothing to migrate this is the factory tree.
    public static func from010(defaults: UserDefaults?, skillsDirectory: URL,
                               factory: HarnessFactory = .standard) -> ConfigTree {
        var tree = ConfigTree.factory
        if let defaults {
            if defaults.bool(forKey: "allowAppleScript"), var mac = tree["harness.mac"] {
                mac.config["appleScript"] = .bool(true)
                tree["harness.mac"] = mac
            }
            if defaults.bool(forKey: "allowShell"), var shell = tree["harness.shell"] {
                shell.disabled = false
                tree["harness.shell"] = shell
            }
            if var settings = tree["settings"] {
                if let provider = defaults.string(forKey: "provider") { settings.config["provider"] = .string(provider) }
                if let route = defaults.object(forKey: "routeWithJev") as? Bool { settings.config["routeWithJev"] = .bool(route) }
                if let model = defaults.string(forKey: "jevModel"), !model.isEmpty { settings.config["jevModel"] = .string(model) }
                tree["settings"] = settings
            }
        }
        // Which harness offers each action, from every harness the tree names (switched on for the lookup).
        var owner: [String: String] = [:]
        for entry in tree.harnessEntries {
            guard let name = entry.config["harness"]?.string else { continue }
            var config = entry.config
            config["appleScript"] = .bool(true)
            for action in (try? factory.make(name, config))?.actionNames ?? [] where owner[action] == nil {
                owner[action] = name
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: skillsDirectory, includingPropertiesForKeys: nil)) ?? []
        let legacy = files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? JSONDecoder().decode(LegacySkill.self, from: Data(contentsOf: $0)) }
            .filter { $0.learned ?? true }
        for skill in legacy {
            let id = Skill.slug(skill.id)
            guard !id.isEmpty, tree["skill." + id] == nil else { continue }
            let steps = (skill.steps ?? []).map { Skill.Step(action: $0.action, arguments: $0.arguments ?? "{}") }
            var needs: [String] = []
            for step in steps {
                if let harness = owner[step.action], !needs.contains(harness) { needs.append(harness) }
            }
            let learned = Skill(id: id, title: skill.title, summary: skill.summary, needs: needs, steps: steps)
            tree.entries.append(learned.entry)
        }
        return tree
    }
}
