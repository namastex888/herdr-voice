import Foundation

/// An entry's state in the host (paper P5). Unloading is a step inside `reconcile`, never a resting state.
public enum EntryStatus: Hashable, Sendable, CustomStringConvertible {
    case active
    /// Waiting on something it needs (a harness that's missing, off or not available here). Not an error: it becomes
    /// active when that appears.
    case inactive(String)
    /// Switched off by the human (`disabled` in the tree).
    case disabled
    /// Its effect threw; it was rolled back and is not retried until its configuration (or what it needs) changes.
    case failed(String)

    public var isActive: Bool { self == .active }

    public var description: String {
        switch self {
        case .active: "active"
        case .inactive(let reason): "inactive (\(reason))"
        case .disabled: "off"
        case .failed(let error): "failed: \(error)"
        }
    }
}

/// A line of the voice's catalog: a harness's controls or a learned skill.
public struct CatalogItem: Hashable, Sendable {
    public let entryID: String
    public let kind: ComponentKind
    public let title: String
    public let summary: String
    /// How to do the task, for a skill that has one; read out by `use_skill`.
    public let playbook: String
}

/// What running components registered. Every table is keyed by entry id, so registrations commute (P4) and an
/// entry's inverse only ever removes its own rows.
public struct Registrations: Sendable {
    public internal(set) var tools: [String: ToolList] = [:]
    public internal(set) var catalog: [String: CatalogItem] = [:]
    /// The config identity, memory and settings publish.
    public internal(set) var published: [String: [String: JSONValue]] = [:]
    public internal(set) var harnesses: [String: any Harness] = [:]
    public internal(set) var skills: [String: Skill] = [:]
}

/// Undoes one registration.
typealias Inverse = @Sendable (inout Registrations) -> Void

/// What an effect registers with, under its entry's id. Each registration records its inverse; the host keeps them
/// per instance and runs them last-in-first-out on unload (P1).
struct Registrar {
    let owner: String
    var tables: Registrations
    private(set) var inverses: [Inverse] = []

    init(owner: String, tables: Registrations) {
        self.owner = owner
        self.tables = tables
    }

    mutating func tools(_ list: ToolList) {
        tables.tools[owner] = list
        inverses.append { [owner] in $0.tools[owner] = nil }
    }

    mutating func catalog(_ item: CatalogItem) {
        tables.catalog[owner] = item
        inverses.append { [owner] in $0.catalog[owner] = nil }
    }

    mutating func publish(_ config: [String: JSONValue]) {
        tables.published[owner] = config
        inverses.append { [owner] in $0.published[owner] = nil }
    }

    mutating func harness(_ harness: any Harness) {
        tables.harnesses[owner] = harness
        inverses.append { [owner] in $0.harnesses[owner] = nil }
    }

    mutating func skill(_ skill: Skill) {
        tables.skills[owner] = skill
        inverses.append { [owner] in $0.skills[owner] = nil }
    }
}

/// What one `reconcile` did, in order.
public struct ReconcileReport: Equatable, Sendable {
    public internal(set) var unloaded: [String] = []
    /// Entries that became active.
    public internal(set) var loaded: [String] = []
    /// Whether any entry's state or registrations changed: the host's one emission per settle (P14).
    public internal(set) var changed = false
}

/// Everything observable about a host: what confluence and containment compare.
public struct HostSnapshot: Equatable, Sendable {
    public let statuses: [String: EntryStatus]
    public let tools: [String: [String]]
    public let catalog: [String: CatalogItem]
    public let published: [String: [String: JSONValue]]
}

/// Runs the configuration tree (paper P1–P8). Each entry is a component of its kind, `(needs, provides, effect)`:
///
/// | kind | needs | provides | effect |
/// |---|---|---|---|
/// | harness | nothing | `harness.<name>` | its actions as tools, a catalog item "controls: <title>" |
/// | identity, memory, settings | nothing | its kind | publishes its config |
/// | skill | `harness.<x>` for each of `needs` | nothing | its procedure tool (if it has steps), a catalog item |
///
/// A value type: copying a host gives the isolated copy a proposal's dry run reconciles (P11). After
/// `reconcile(tree)` the state depends only on `tree` (confluence, P8).
public struct ComponentHost: Sendable {
    private struct Instance: Sendable {
        var entry: ConfigEntry
        var status: EntryStatus
        var provides: Set<String> = []
        var inverses: [Inverse] = []
    }

    private enum Loaded {
        case active(provides: Set<String>)
        case unavailable(String)
    }

    public let factory: HarnessFactory
    /// The tree last reconciled to.
    public private(set) var tree = ConfigTree(entries: [])
    public private(set) var registrations = Registrations()
    private var instances: [String: Instance] = [:]

    public init(factory: HarnessFactory) {
        self.factory = factory
    }

    // MARK: reading

    public func status(_ id: String) -> EntryStatus? { instances[id]?.status }

    public var statuses: [String: EntryStatus] { instances.mapValues(\.status) }

    /// Entries in tree order (a duplicated id counts once, as its first occurrence).
    public var entries: [ConfigEntry] {
        var seen = Set<String>()
        return tree.entries.filter { seen.insert($0.id).inserted }
    }

    public func isActive(_ id: String) -> Bool { instances[id]?.status == .active }

    /// The capabilities an entry needs: `harness.<x>` for each harness a skill names.
    public static func needs(of entry: ConfigEntry) -> Set<String> {
        guard entry.kind == .skill else { return [] }
        return Set((entry.config["needs"]?.array ?? []).compactMap(\.string).map { "harness." + $0 })
    }

    /// Active entries providing `capability`, in tree order.
    public func providers(of capability: String) -> [String] {
        entries.map(\.id).filter { instances[$0]?.status == .active && instances[$0]?.provides.contains(capability) == true }
    }

    public var snapshot: HostSnapshot {
        HostSnapshot(statuses: statuses, tools: registrations.tools.mapValues(\.names), catalog: registrations.catalog,
                     published: registrations.published)
    }

    // MARK: reconcile

    /// Settles the host on `next`: unloads what changed or left (dependents before the providers they need, P6),
    /// then loads what can run (providers first). A changed entry reloads; an entry whose needs are missing waits
    /// inactive; an effect that throws is rolled back and marks only its own entry failed (P7). `onStep` sees the
    /// host after every single load or unload (for the ordering checks).
    @discardableResult
    public mutating func reconcile(_ next: ConfigTree, onStep: ((ComponentHost) -> Void)? = nil) -> ReconcileReport {
        let before = snapshot
        var report = ReconcileReport()
        var desired: [String: ConfigEntry] = [:]
        var order: [String] = []
        for entry in next.entries where desired[entry.id] == nil {
            desired[entry.id] = entry
            order.append(entry.id)
        }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        tree = next

        // 1. Unload active entries that changed, left, or lost their harness, with everything that depends on them.
        var dirty = Set(instances.filter { id, instance in
            instance.status == .active && (desired[id] != instance.entry || !(registrations.harnesses[id]?.isAvailable ?? true))
        }.keys)
        var grew = true
        while grew {
            grew = false
            let leaving = Set(dirty.flatMap { instances[$0]?.provides ?? [] })
            for (id, instance) in instances where instance.status == .active && !dirty.contains(id)
                && !Self.needs(of: instance.entry).isDisjoint(with: leaving) {
                dirty.insert(id)
                grew = true
            }
        }
        var changedProviders = Set<String>()
        while !dirty.isEmpty {
            // Ready: nothing else still loaded and leaving needs what it provides.
            var ready = dirty.filter { id in
                let provides = instances[id]?.provides ?? []
                return !dirty.contains { $0 != id && !Self.needs(of: instances[$0]!.entry).isDisjoint(with: provides) }
            }
            if ready.isEmpty { ready = dirty } // a cycle can't arise from the kinds above; never spin on one
            for id in ready.sorted(by: { (position[$0] ?? .max, $0) > (position[$1] ?? .max, $1) }) {
                changedProviders.formUnion(instances[id]?.provides ?? [])
                unload(id)
                dirty.remove(id)
                report.unloaded.append(id)
                onStep?(self)
            }
        }

        // 2. Forget entries that left the tree.
        for id in instances.keys where desired[id] == nil { instances[id] = nil }

        // 3. Load what can run, providers first, to a fixpoint. A failed entry whose config and providers are unchanged
        //    keeps its failure instead of being retried.
        var pending = order.filter { instances[$0]?.status != .active }
        var progress = true
        while progress {
            progress = false
            var provided = Set(instances.values.filter { $0.status == .active }.flatMap(\.provides))
            for id in pending {
                let entry = desired[id]!
                if entry.disabled {
                    instances[id] = Instance(entry: entry, status: .disabled)
                    pending.removeAll { $0 == id }
                    progress = true
                    continue
                }
                let needs = Self.needs(of: entry)
                guard needs.isSubset(of: provided) else { continue }
                if case .failed? = instances[id]?.status, instances[id]?.entry == entry {
                    continue // decided below, once every provider that can load has
                }
                if load(id, entry) {
                    report.loaded.append(id)
                    provided.formUnion(instances[id]?.provides ?? [])
                    changedProviders.formUnion(instances[id]?.provides ?? [])
                }
                pending.removeAll { $0 == id }
                progress = true
                onStep?(self)
            }
            if progress { continue }
            // Failed entries with their needs met: kept failed unless what they need changed in this reconcile.
            for id in pending {
                let entry = desired[id]!
                let needs = Self.needs(of: entry)
                guard needs.isSubset(of: provided) else { continue }
                pending.removeAll { $0 == id }
                progress = true
                guard !needs.isDisjoint(with: changedProviders) else { continue }
                if load(id, entry) { report.loaded.append(id) }
                onStep?(self)
            }
        }
        for id in pending {
            let entry = desired[id]!
            let provided = Set(instances.values.filter { $0.status == .active }.flatMap(\.provides))
            let missing = Self.needs(of: entry).subtracting(provided).sorted()
                .map { $0.hasPrefix("harness.") ? String($0.dropFirst("harness.".count)) : $0 }
            instances[id] = Instance(entry: entry, status: .inactive("needs " + missing.joined(separator: ", ")))
        }
        report.changed = snapshot != before
        return report
    }

    private mutating func unload(_ id: String) {
        guard var instance = instances[id] else { return }
        for inverse in instance.inverses.reversed() { inverse(&registrations) }
        instance.inverses = []
        instance.provides = []
        instance.status = .inactive("unloaded")
        instances[id] = instance
    }

    /// Runs `entry`'s effect into a scratch copy of the tables: kept if it completes, dropped (with its partial
    /// registrations) if it throws. True when the entry became active.
    private mutating func load(_ id: String, _ entry: ConfigEntry) -> Bool {
        var registrar = Registrar(owner: id, tables: registrations)
        do {
            switch try effect(entry, &registrar) {
            case .active(let provides):
                registrations = registrar.tables
                instances[id] = Instance(entry: entry, status: .active, provides: provides, inverses: registrar.inverses)
                return true
            case .unavailable(let reason):
                instances[id] = Instance(entry: entry, status: .inactive(reason))
                return false
            }
        } catch {
            instances[id] = Instance(entry: entry, status: .failed(String(describing: error)))
            return false
        }
    }

    // MARK: effects

    private func effect(_ entry: ConfigEntry, _ registrar: inout Registrar) throws -> Loaded {
        switch entry.kind {
        case .harness:
            guard let name = entry.config["harness"]?.string, !name.isEmpty else {
                throw ComponentError("a harness entry needs config.harness")
            }
            let harness = try factory.make(name, entry.config)
            guard harness.isAvailable else { return .unavailable("\(harness.title) isn't available on this Mac") }
            registrar.harness(harness)
            registrar.tools(harness.actions)
            registrar.catalog(CatalogItem(entryID: entry.id, kind: .harness, title: "controls: \(harness.title)",
                                          summary: harness.summary, playbook: ""))
            return .active(provides: ["harness." + name])
        case .identity:
            guard let name = try Self.text(entry, "name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ComponentError("identity needs a name")
            }
            for key in ["role", "personality", "instructions"] { _ = try Self.text(entry, key) }
            registrar.publish(entry.config)
            return .active(provides: ["identity"])
        case .memory:
            if let facts = entry.config["facts"], !facts.isNull,
               !(facts.array?.allSatisfy { $0.string != nil } ?? false) {
                throw ComponentError("memory.facts must be a list of sentences")
            }
            registrar.publish(entry.config)
            return .active(provides: ["memory"])
        case .settings:
            for key in ["voice", "jevModel", "provider", "activation", "activationKey", "wakePhrase", "accent"] {
                _ = try Self.text(entry, key)
            }
            if let seconds = entry.config["followUpSeconds"], !seconds.isNull, seconds.number == nil {
                throw ComponentError("settings.followUpSeconds must be a number")
            }
            if let route = entry.config["routeWithJev"], !route.isNull, route.bool == nil {
                throw ComponentError("settings.routeWithJev must be true or false")
            }
            registrar.publish(entry.config)
            return .active(provides: ["settings"])
        case .skill:
            let skill = try Skill(entry: entry)
            var offered = Set<String>()
            for need in skill.needs {
                for provider in providers(of: "harness." + need) {
                    offered.formUnion(registrations.harnesses[provider]?.actionNames ?? [])
                }
            }
            try skill.validate { offered.contains($0) }
            if !skill.steps.isEmpty { registrar.tools(ToolList([skill.procedureSchema])) }
            registrar.skill(skill)
            registrar.catalog(CatalogItem(entryID: entry.id, kind: .skill, title: skill.title, summary: skill.summary,
                                          playbook: skill.playbook))
            return .active(provides: [])
        default:
            throw ComponentError("unknown kind \(entry.kind)")
        }
    }

    /// An optional text field: nil when absent or null; throws when it is something else.
    private static func text(_ entry: ConfigEntry, _ key: String) throws -> String? {
        switch entry.config[key] {
        case nil, .null?: return nil
        case .string(let value)?: return value
        default: throw ComponentError("\(entry.id).\(key) must be text")
        }
    }
}

extension Skill {
    /// The tool its procedure runs by, as the wires send it.
    var procedureSchema: [String: Any] {
        let plan = steps.map(\.action).joined(separator: ", ")
        return HerdrTools.fn(toolName, "\(title): \(summary) (a skill you learned; runs \(plan))",
                             ["confirmed": HerdrTools.confirmedField], [])
    }
}
