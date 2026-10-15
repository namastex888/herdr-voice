import Foundation

/// What the live session should offer after a settle: the registry emits one per reconcile or activation change
/// (P14), and the app turns it into session updates, never a "revert".
public struct RegistryEmission: Sendable {
    /// The self tools plus the active set's tools (`SkillRegistry.activeTools`).
    public let tools: ToolList
    public let instructions: String
    public let active: [String]
    public let tree: ConfigTree
}

/// A harness entry as the app shows it.
public struct HarnessState: Sendable {
    public let entryID: String
    /// `mac`, `herdr`, `shell`.
    public let name: String
    public let title: String
    public let summary: String
    public let status: EntryStatus
    /// Its actions, also while it is off or unavailable.
    public let actions: ToolList
}

/// The companion's `ToolHost`, built on the configuration tree. A `ComponentHost` runs the tree; the registry keeps
/// which skills are in play (runtime state, never in the tree), offers the self tools plus the active set's tools,
/// and runs each call on the harness that owns it. Learned procedures replay their steps through `call`, so every
/// step meets the same gates.
///
/// The tree changes in exactly two ways: a proposal the human said yes to (`propose_change`, `learn_skill`,
/// `forget_skill`, `remember`, `revert_change`, each armed in the `ConfirmGate` as the exact proposal), and the app's
/// own UI (`applyUserEdit` and the helpers beside it), which no tool reaches.
public final class SkillRegistry: ToolHost, @unchecked Sendable { // all mutable state lives under `lock`
    /// Learned skills kept in play besides every harness's controls: the latest and the ones just before it.
    public static let activeLimit = 3
    public static let changeLogLimit = 200
    /// Tools the voice always has for itself.
    public static let selfTools = ["describe_self", "propose_change", "learn_skill", "forget_skill", "remember",
                                   "revert_change", "list_changes", "use_skill"]

    private struct State {
        var host: ComponentHost
        var changes: [ChangeRecord]
        var metrics: GrowthMetrics
        /// Skill entry ids in play, most recent first. Every active harness's controls are always in play.
        var recentSkills: [String] = []
        var onChange: (@Sendable (RegistryEmission) -> Void)?
    }

    private let lock = NSLock()
    private var state: State
    private let store: CompanionStore?
    private let gate: ConfirmGate
    private let clock: @Sendable () -> Date

    /// Loads the tree from `store` (migrating 0.1.0's state from `legacyDefaults` and its skills folder the first
    /// time) or starts from `tree` (the factory tree by default); `store` nil keeps everything in memory (tests).
    public init(store: CompanionStore?, factory: HarnessFactory = .standard, gate: ConfirmGate = .shared,
                legacyDefaults: UserDefaults? = nil, tree: ConfigTree? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.gate = gate
        self.clock = clock
        let initial = tree ?? store?.loadTree(legacyDefaults: legacyDefaults, factory: factory) ?? .factory
        var host = ComponentHost(factory: factory)
        host.reconcile(initial)
        state = State(host: host, changes: store?.loadChanges() ?? [], metrics: store?.loadMetrics() ?? GrowthMetrics())
    }

    /// Called (on any thread) once per settle: after a change applies, `refresh` finds something new, or the
    /// skills in play change.
    public func onChange(_ handler: @escaping @Sendable (RegistryEmission) -> Void) {
        lock.withLock { state.onChange = handler }
    }

    // MARK: reading

    public var tree: ConfigTree { lock.withLock { state.host.tree } }
    public var host: ComponentHost { lock.withLock { state.host } }
    public var changes: [ChangeRecord] { lock.withLock { state.changes } }
    public var metrics: GrowthMetrics { lock.withLock { state.metrics } }

    public func status(of entryID: String) -> EntryStatus? { lock.withLock { state.host.status(entryID) } }

    /// Every learned skill in the tree, active or not, in tree order.
    public var skills: [Skill] {
        lock.withLock { state.host.entries.filter { $0.kind == .skill }.compactMap { try? Skill(entry: $0) } }
    }

    public var harnesses: [HarnessState] {
        lock.withLock {
            let host = state.host
            return host.entries.filter { $0.kind == .harness }.map { entry in
                let name = entry.config["harness"]?.string ?? ""
                let harness = host.registrations.harnesses[entry.id] ?? (try? host.factory.make(name, entry.config))
                return HarnessState(entryID: entry.id, name: name, title: harness?.title ?? name,
                                    summary: harness?.summary ?? "", status: host.status(entry.id) ?? .inactive("unknown"),
                                    actions: harness?.actions ?? ToolList([]))
            }
        }
    }

    public var profile: CompanionVoice.Profile { lock.withLock { Self.profile(state.host) } }
    /// The voice's standing instructions for the current configuration.
    public var instructions: String { CompanionVoice.instructions(profile) }
    /// What the voice says first; a new hire's names its harnesses and asks for a first task.
    public var greeting: String { CompanionVoice.greeting(profile) }

    /// What a turn can be routed to: active learned skills and every active harness's raw controls.
    public var routeOptions: [RouteOption] { lock.withLock { Self.routeOptions(state.host) } }

    // MARK: the active set (runtime state)

    /// What is in play: the recent skills, then every active harness.
    public var active: [String] { lock.withLock { Self.active(state) } }

    /// Puts a skill first among those in play (a harness's controls are always in play). Accepts entry ids,
    /// skill slugs and harness names. False when nothing changed or `id` isn't an active skill or harness.
    @discardableResult
    public func activate(_ id: String) -> Bool {
        let emission = lock.withLock { () -> RegistryEmission? in
            guard let entry = Self.resolve(id, in: state.host), state.host.isActive(entry),
                  state.host.tree[entry]?.kind == .skill else { return nil }
            let next = Array(([entry] + state.recentSkills.filter { $0 != entry }).prefix(Self.activeLimit))
            guard next != state.recentSkills else { return nil }
            state.recentSkills = next
            return emission()
        }
        emit(emission)
        return emission != nil
    }

    // MARK: tools

    /// Every tool, for providers that can't change tools mid-session.
    public var tools: ToolList {
        lock.withLock { Self.toolList(state, entries: Set(state.host.entries.map(\.id))) }
    }

    /// The self tools plus the active set's tools: what a session that routes per turn offers.
    public var activeTools: ToolList { lock.withLock { Self.activeTools(state) } }

    public func call(_ name: String, arguments: String, userInitiated: Bool) -> HerdrTools.Outcome {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        let confirmed = args["confirmed"] as? Bool ?? false
        switch name {
        case "describe_self": return Self.outcome(describeSelf())
        case "propose_change":
            do {
                return Self.outcome(propose(name, try Proposal(arguments: args), confirmed: confirmed))
            } catch {
                return Self.outcome("error: \(error). Nothing changed.")
            }
        case "learn_skill": return Self.outcome(learnSkill(args, confirmed: confirmed))
        case "forget_skill": return Self.outcome(forgetSkill(args["skill"] as? String ?? "", confirmed: confirmed))
        case "remember": return Self.outcome(remember(args["fact"] as? String ?? "", confirmed: confirmed))
        case "revert_change": return Self.outcome(revertChange(args["change"] as? String ?? "", confirmed: confirmed))
        case "list_changes": return Self.outcome(listChanges())
        case "use_skill": return Self.outcome(useSkill(args["skill"] as? String ?? ""))
        default: break
        }
        let target = lock.withLock { () -> (skill: Skill?, harness: (any Harness)?) in
            let host = state.host
            if let skill = host.registrations.skills.values.first(where: { $0.toolName == name && !$0.steps.isEmpty }) {
                return (skill, nil)
            }
            let owner = host.entries.first { host.isActive($0.id) && host.registrations.tools[$0.id]?.names.contains(name) == true
                && host.registrations.harnesses[$0.id] != nil }
            return (nil, owner.flatMap { host.registrations.harnesses[$0.id] })
        }
        if let skill = target.skill {
            return runProcedure(skill, confirmed: confirmed, userInitiated: userInitiated)
        }
        guard let harness = target.harness else { return Self.outcome("error: unknown tool \(name)") }
        return harness.call(name, arguments: arguments, userInitiated: userInitiated)
    }

    public func settle(_ target: String, done: @escaping @Sendable (String) -> Void) {
        HerdrTools.settle(target, done: done)
    }

    public func watchPane(_ watch: HerdrTools.PaneWatch, done: @escaping @Sendable (String) -> Void) {
        HerdrTools.watchPane(watch, done: done)
    }

    // MARK: the human's own edits (the app's UI; no tool reaches these)

    /// Applies the human's edit directly, transactionally, and logs it as theirs. The human may change anything,
    /// including what they own (harness entries, `disabled`, the provider). `edit` runs under the registry's lock, so
    /// it must not call back into the registry.
    @discardableResult
    public func applyUserEdit(_ summary: String, _ edit: (inout ConfigTree) throws -> Void) throws -> ChangeRecord {
        try commit(summary: summary, by: .user, revertOf: nil, checkFailures: false) { host in
            var tree = host.tree
            try edit(&tree)
            return tree
        }
    }

    public func forgetSkill(_ id: String) throws {
        let entry = id.hasPrefix(Skill.entryPrefix) ? id : Skill.entryPrefix + id
        let title = tree[entry]?.config["title"]?.string ?? id
        try applyUserEdit("Forgot the skill \(title)") { $0[entry] = nil }
    }

    /// Switches an entry (a harness, usually) on or off.
    public func setDisabled(_ entryID: String, _ disabled: Bool) throws {
        try applyUserEdit("\(disabled ? "Switched off" : "Switched on") \(entryID)") { tree in
            guard var entry = tree[entryID] else { throw ComponentError("there is no \(entryID)") }
            entry.disabled = disabled
            tree[entryID] = entry
        }
    }

    /// Sets one config field of an entry (`harness.mac` `appleScript`, `settings` `provider`, `identity` `name`).
    public func setField(_ entryID: String, _ key: String, _ value: JSONValue) throws {
        try applyUserEdit("Set \(entryID).\(key)") { tree in
            guard var entry = tree[entryID] else { throw ComponentError("there is no \(entryID)") }
            entry.config[key] = value
            tree[entryID] = entry
        }
    }

    /// The human's revert: every entry the change touched goes back as it was before it.
    @discardableResult
    public func revert(_ changeID: String) throws -> ChangeRecord {
        guard let record = changes.first(where: { $0.id == changeID }) else { throw ComponentError("there is no change \(changeID)") }
        return try commit(summary: "Undid \(record.id): \(record.summary)", by: .user, revertOf: record.id,
                          checkFailures: false) { host in
            record.revertTarget(from: host.tree, keepHumanOwned: false)
        }
    }

    /// Back to a new hire: no skills, factory identity, memory and settings; the harnesses and provider stay.
    @discardableResult
    public func resetToNewHire() throws -> ChangeRecord {
        try applyUserEdit("Reset to a new hire") { $0 = $0.resetToNewHire() }
    }

    /// Reconciles again, so a harness that appeared (Herdr installed) or went away is picked up.
    public func refresh() {
        let emission = lock.withLock { () -> RegistryEmission? in
            let report = state.host.reconcile(state.host.tree)
            pruneActive()
            return report.changed ? emission() : nil
        }
        emit(emission)
    }

    // MARK: proposals

    /// Steps 1 and 2: proposable paths, well-formed values and skills, then a dry run on an isolated copy of `host`.
    /// Returns the proposed tree, or why it is refused; never changes anything.
    private static func prepare(_ proposal: Proposal, on host: ComponentHost) throws -> ConfigTree {
        for change in proposal.changes { try Governance.check(change) }
        let proposed = try host.tree.applying(proposal)
        let changed = host.tree.changedIDs(to: proposed)
        guard !changed.isEmpty else { throw ComponentError("that changes nothing") }
        for id in changed {
            guard let entry = proposed[id], entry.kind == .skill else { continue }
            try staticCheck(try Skill(entry: entry), in: proposed, factory: host.factory)
        }
        var copy = host
        copy.reconcile(proposed)
        for id in changed {
            if case .failed(let error)? = copy.status(id) { throw ComponentError("refused: \(id) would fail (\(error))") }
        }
        return proposed
    }

    /// A skill is well formed against the harnesses it names, whether or not they can run right now.
    private static func staticCheck(_ skill: Skill, in tree: ConfigTree, factory: HarnessFactory) throws {
        var offered = Set<String>()
        for need in skill.needs {
            guard let entry = tree.harnessEntries.first(where: { $0.config["harness"]?.string == need }) else {
                throw ComponentError("there is no harness called \(need)")
            }
            offered.formUnion((try? factory.make(need, entry.config))?.actionNames ?? [])
        }
        try skill.validate { offered.contains($0) }
    }

    /// Validate, dry run, ask (the gate arms this exact proposal), and only on the human's own yes apply.
    private func propose(_ tool: String, _ proposal: Proposal, confirmed: Bool, revertOf: String? = nil,
                         activate: String? = nil) -> String {
        let host = self.host
        do {
            _ = try Self.prepare(proposal, on: host)
        } catch {
            return "error: \(error). Nothing changed."
        }
        if let stop = HerdrTools.confirmStep(tool, action: proposal.gateKey, question: "may I " + proposal.spoken(in: host.tree),
                                             confirmed: confirmed, gate) {
            return stop
        }
        do {
            let record = try commit(summary: proposal.summary, by: .assistant, revertOf: revertOf, checkFailures: true,
                                    activate: activate) { host in try Self.prepare(proposal, on: host) }
            return "Done (change \(record.id)): \(proposal.summary)."
        } catch {
            return "error: \(error). Nothing changed."
        }
    }

    /// Step 4: back up the tree, reconcile the live host, persist; on any failure the backup stands (in memory and on
    /// disk). Then logs the change. `make` builds the next tree from the live host, under the lock.
    private func commit(summary: String, by author: ChangeRecord.Author, revertOf: String?, checkFailures: Bool,
                        activate: String? = nil, make: (ComponentHost) throws -> ConfigTree) throws -> ChangeRecord {
        let (record, emission) = try lock.withLock { () throws -> (ChangeRecord, RegistryEmission?) in
            let before = state.host.tree
            let after = try make(state.host)
            let changed = before.changedIDs(to: after)
            guard !changed.isEmpty else { throw ComponentError("that changes nothing") }
            var host = state.host // the live host stays the backup until everything below went through
            host.reconcile(after)
            if checkFailures {
                for id in changed {
                    if case .failed(let error)? = host.status(id) { throw ComponentError("\(id) failed (\(error))") }
                }
            }
            if let store {
                do {
                    try store.save(after)
                } catch {
                    try? store.save(before)
                    throw ComponentError("couldn't save the change: \(error.localizedDescription)")
                }
            }
            state.host = host
            let number = (state.changes.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
            // Whole seconds: what changes.json keeps (ISO 8601), so a reloaded log equals the live one.
            let time = Date(timeIntervalSince1970: clock().timeIntervalSince1970.rounded(.down))
            let record = ChangeRecord(id: "c\(number)", summary: summary, before: before, after: after, time: time,
                                      by: author, revertOf: revertOf)
            state.changes = Array((state.changes + [record]).suffix(Self.changeLogLimit))
            try? store?.saveChanges(state.changes)
            if revertOf != nil {
                state.metrics.reverted += 1
            } else if author == .assistant {
                state.metrics.proposalsApplied += 1
                state.metrics.skillsTaught += changed.filter { before[$0] == nil && after[$0]?.kind == .skill }.count
            }
            try? store?.saveMetrics(state.metrics)
            pruneActive()
            if let activate, host.isActive(activate) {
                state.recentSkills = Array(([activate] + state.recentSkills.filter { $0 != activate }).prefix(Self.activeLimit))
            }
            return (record, emission())
        }
        emit(emission)
        return record
    }

    // MARK: self tools

    private func learnSkill(_ args: [String: Any], confirmed: Bool) -> String {
        let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let id = Skill.slug(title)
        guard !id.isEmpty else { return "error: a skill needs a title the user can say. Nothing changed." }
        var steps: [Skill.Step] = []
        for (index, raw) in (args["steps"] as? [Any] ?? []).enumerated() {
            guard let step = raw as? [String: Any], let action = step["action"] as? String else {
                return "error: step \(index + 1) needs an action. Nothing changed."
            }
            let arguments: String
            switch step["arguments"] {
            case let text as String: arguments = text
            case let object as [String: Any]: arguments = JSONValue(any: object)?.canonical ?? "{}"
            default: arguments = "{}"
            }
            steps.append(Skill.Step(action: action, arguments: arguments))
        }
        let host = self.host
        var needs: [String] = []
        let offered = host.tree.harnessEntries.compactMap { entry -> (String, Set<String>)? in
            guard let name = entry.config["harness"]?.string,
                  let harness = try? host.factory.make(name, entry.config) else { return nil }
            return (name, Set(harness.actionNames))
        }
        for step in steps {
            if let owner = offered.first(where: { $0.1.contains(step.action) })?.0, !needs.contains(owner) { needs.append(owner) }
        }
        let skill = Skill(id: id, title: title, summary: (args["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                          needs: needs, steps: steps, playbook: args["playbook"] as? String ?? "")
        var changes: [Proposal.Change] = []
        if host.tree[skill.entryID] != nil { changes.append(.init(op: .removeEntry, path: skill.entryID)) }
        changes.append(.init(op: .addEntry, path: skill.entryID, value: .object(skill.config)))
        let summary = (host.tree[skill.entryID] == nil ? "Learn the skill " : "Relearn the skill ") + title
        return propose("learn_skill", Proposal(summary: summary, changes: changes), confirmed: confirmed,
                       activate: skill.entryID)
    }

    private func forgetSkill(_ id: String, confirmed: Bool) -> String {
        let host = self.host
        guard let entry = Self.resolve(id, in: host), let config = host.tree[entry], config.kind == .skill else {
            return "error: there is no learned skill \(id). Nothing changed."
        }
        let title = config.config["title"]?.string ?? entry
        return propose("forget_skill", Proposal(summary: "Forget the skill \(title)",
                                                changes: [.init(op: .removeEntry, path: entry)]), confirmed: confirmed)
    }

    private func remember(_ fact: String, confirmed: Bool) -> String {
        let fact = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        return propose("remember", Proposal(summary: "Remember: \(fact)",
                                            changes: [.init(op: .append, path: "memory.facts", value: .string(fact))]),
                       confirmed: confirmed)
    }

    private func revertChange(_ id: String, confirmed: Bool) -> String {
        let (record, current) = lock.withLock { (state.changes.first { $0.id == id }, state.host.tree) }
        guard let record else { return "error: there is no change \(id); list_changes shows them. Nothing changed." }
        let target = record.revertTarget(from: current, keepHumanOwned: true)
        let proposal = Proposal.between(current, target, summary: "Undo \(record.id): \(record.summary)")
        guard !proposal.changes.isEmpty else {
            return "error: nothing of \(record.id) is left to undo that you may change. Nothing changed."
        }
        return propose("revert_change", proposal, confirmed: confirmed, revertOf: record.id)
    }

    private func listChanges() -> String {
        let changes = self.changes
        guard !changes.isEmpty else { return "No changes yet." }
        let formatter = ISO8601DateFormatter()
        return changes.suffix(10).reversed().map { change in
            "\(change.id) (\(change.by == .assistant ? "proposed by you" : "made by the user"), "
                + "\(formatter.string(from: change.time))): \(change.summary)"
        }.joined(separator: "\n")
    }

    private func useSkill(_ id: String) -> String {
        let reply = lock.withLock { () -> (String, RegistryEmission?) in
            let host = state.host
            guard let entry = Self.resolve(id, in: host), let config = host.tree[entry] else {
                let known = Self.routeOptions(host).map(\.id).joined(separator: ", ")
                return ("error: there is no skill or harness \(id). You can use: \(known)", nil)
            }
            guard host.isActive(entry) else {
                return ("error: \(entry) can't be used right now: \(host.status(entry)?.description ?? "unknown")", nil)
            }
            if config.kind == .harness {
                let title = host.registrations.harnesses[entry]?.title ?? entry
                return ("The \(title) controls are loaded: " + (host.registrations.tools[entry]?.names ?? [])
                    .joined(separator: ", "), nil)
            }
            guard let skill = host.registrations.skills[entry] else { return ("error: \(entry) isn't a skill", nil) }
            var changed = false
            let next = Array(([entry] + state.recentSkills.filter { $0 != entry }).prefix(Self.activeLimit))
            if next != state.recentSkills {
                state.recentSkills = next
                changed = true
            }
            var tools = skill.steps.isEmpty ? [] : [skill.toolName]
            for need in skill.needs {
                for provider in host.providers(of: "harness." + need) {
                    tools += host.registrations.tools[provider]?.names ?? []
                }
            }
            var text = "Loaded \(skill.title). "
                + (skill.steps.isEmpty ? "" : "Run it with \(skill.toolName). ")
                + "Its tools are ready: " + tools.joined(separator: ", ") + "."
            if !skill.playbook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text += "\nHow to do it (the user taught you):\n" + skill.playbook
            }
            return (text, changed ? emission() : nil)
        }
        emit(reply.1)
        return reply.0
    }

    private func describeSelf() -> String {
        let (host, changes) = lock.withLock { (state.host, state.changes.count) }
        let profile = Self.profile(host)
        let settings = host.registrations.published["settings"] ?? host.tree["settings"]?.config ?? [:]
        var lines = ["I am \(profile.name), \(profile.role). Manner: \(profile.personality)."]
        lines.append("How the user likes things done: "
            + (profile.instructions.isEmpty ? "nothing learned yet." : profile.instructions))
        lines.append("What I remember: " + (profile.facts.isEmpty ? "nothing yet." : profile.facts.joined(separator: " | ")))
        lines.append("Settings: voice \(settings["voice"]?.string ?? "default"), routing "
            + ((settings["routeWithJev"]?.bool ?? true) ? "with Jev (\(settings["jevModel"]?.string ?? JevRouter.defaultModel))" : "by words")
            + ". Harnesses, the voice model and the confirmation rules are the user's to change.")
        lines.append("Harnesses:")
        for entry in host.entries where entry.kind == .harness {
            let title = Self.harnessTitle(entry, in: host)
            let status = host.status(entry.id) ?? .inactive("unknown")
            lines.append("- \(title) (\(entry.id)): " + (status == .disabled ? "off (the user can switch it on in the app)"
                : status.description))
        }
        let skills = host.entries.filter { $0.kind == .skill }
        lines.append(skills.isEmpty ? "Skills: none yet." : "Skills:")
        for entry in skills {
            let skill = try? Skill(entry: entry)
            var line = "- \(entry.id) (\(skill?.title ?? "?")): \(skill?.summary ?? "")"
            if let skill, !skill.steps.isEmpty { line += "; steps: " + skill.steps.map(\.action).joined(separator: ", ") }
            if let skill, !skill.playbook.isEmpty { line += "; has how-to notes" }
            line += "; " + (host.status(entry.id)?.description ?? "unknown")
            lines.append(line)
        }
        lines.append("Changes so far: \(changes) (list_changes shows them).")
        return lines.joined(separator: "\n")
    }

    /// Runs a procedure's steps in order through `call` and stops at the first that doesn't go through. Run on the
    /// user's word, its steps count as the user's; prompted by a report instead, the whole skill first needs a yes.
    private func runProcedure(_ skill: Skill, confirmed: Bool, userInitiated: Bool) -> HerdrTools.Outcome {
        if !userInitiated, let stop = HerdrTools.confirmStep(skill.toolName, action: "skill:" + skill.toolName,
                                                             question: "run your skill \(skill.title)",
                                                             confirmed: confirmed, gate) {
            return Self.outcome(stop)
        }
        let procedures = Set(host.registrations.skills.values.map(\.toolName))
        var lines: [String] = []
        var watch: String?
        var paneWatch: HerdrTools.PaneWatch?
        var stopped = false
        for (index, step) in skill.steps.enumerated() {
            // Only a harness action replays: never a self tool, another procedure, a step carrying a confirmation,
            // or an action that always needs a spoken yes (a hand-edited config.json could hold any of them).
            let arguments = (try? JSONSerialization.jsonObject(with: Data(step.arguments.utf8)) as? [String: Any]) ?? nil
            let result = Skill.unrepeatable.contains(step.action) || Self.selfTools.contains(step.action)
                || procedures.contains(step.action) || arguments == nil || arguments?["confirmed"] != nil
                ? Self.outcome("error: \(step.action) can't run as a step of a skill")
                : call(step.action, arguments: step.arguments, userInitiated: true)
            watch = watch ?? result.watch
            paneWatch = paneWatch ?? result.paneWatch
            lines.append("\(index + 1). \(step.action): \(result.output)")
            if ["error", "CONFIRMATION REQUIRED", "NOT DONE"].contains(where: result.output.hasPrefix) {
                lines.append("Stopped at step \(index + 1) of \(skill.steps.count).")
                stopped = true
                break
            }
        }
        lock.withLock {
            state.metrics.replays += 1
            if stopped { state.metrics.replayFailures += 1 }
            try? store?.saveMetrics(state.metrics)
        }
        var outcome = HerdrTools.Outcome(output: "Ran \(skill.title):\n" + lines.joined(separator: "\n"), watch: watch)
        outcome.paneWatch = paneWatch
        return outcome
    }

    // MARK: building blocks (pure, over a snapshot of the state)

    /// `skill.start-my-day`, `start-my-day`, `skill_start_my_day`, `harness.mac` or `mac` → the entry id.
    private static func resolve(_ id: String, in host: ComponentHost) -> String? {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.tree[id] != nil { return id }
        if host.tree[Skill.entryPrefix + id] != nil { return Skill.entryPrefix + id }
        if let skill = host.registrations.skills.values.first(where: { $0.toolName == id }) { return skill.entryID }
        return host.entries.first { $0.kind == .harness && $0.config["harness"]?.string == id }?.id
    }

    private static func profile(_ host: ComponentHost) -> CompanionVoice.Profile {
        let identity = host.registrations.published["identity"] ?? ConfigTree.defaultIdentity
        let memory = host.registrations.published["memory"] ?? [:]
        var profile = CompanionVoice.Profile(
            name: identity["name"]?.string ?? "Companion", role: identity["role"]?.string ?? "",
            personality: identity["personality"]?.string ?? "", instructions: identity["instructions"]?.string ?? "",
            facts: (memory["facts"]?.array ?? []).compactMap(\.string))
        for entry in host.entries {
            guard let item = host.registrations.catalog[entry.id] else {
                if entry.kind == .harness, let status = host.status(entry.id) {
                    let title = harnessTitle(entry, in: host)
                    profile.unavailable.append("\(title), " + (status == .disabled ? "switched off by the user" : status.description))
                }
                continue
            }
            if entry.kind == .harness { profile.controls.append(item) } else if entry.kind == .skill { profile.skills.append(item) }
        }
        return profile
    }

    /// A harness entry's title, also while it is off or unavailable.
    private static func harnessTitle(_ entry: ConfigEntry, in host: ComponentHost) -> String {
        let name = entry.config["harness"]?.string ?? ""
        return (host.registrations.harnesses[entry.id] ?? (try? host.factory.make(name, entry.config)))?.title
            ?? (name.isEmpty ? entry.id : name)
    }

    private static func routeOptions(_ host: ComponentHost) -> [RouteOption] {
        var skills: [RouteOption] = []
        var harnesses: [RouteOption] = []
        for entry in host.entries where host.isActive(entry.id) {
            if let skill = host.registrations.skills[entry.id] {
                skills.append(RouteOption(id: entry.id, title: skill.title, summary: skill.summary,
                                          keywords: skill.steps.map(\.action), learned: true))
            } else if let harness = host.registrations.harnesses[entry.id] {
                let words = harness.actions.definitions.flatMap {
                    [$0["name"] as? String ?? "", $0["description"] as? String ?? ""]
                }
                harnesses.append(RouteOption(id: entry.id, title: harness.title, summary: harness.summary,
                                             keywords: words, learned: false))
            }
        }
        return skills + harnesses
    }

    private static func active(_ state: State) -> [String] {
        state.recentSkills + state.host.entries.filter { $0.kind == .harness && state.host.isActive($0.id) }.map(\.id)
    }

    private static func activeTools(_ state: State) -> ToolList {
        var entries = Set(state.recentSkills)
        for entry in state.host.entries where entry.kind == .harness && state.host.isActive(entry.id) { entries.insert(entry.id) }
        return toolList(state, entries: entries)
    }

    /// The self tools, then the tools of `entries` in tree order (a skill brings its harnesses' actions).
    private static func toolList(_ state: State, entries wanted: Set<String>) -> ToolList {
        let host = state.host
        var wanted = wanted
        for id in wanted {
            for need in host.registrations.skills[id]?.needs ?? [] { wanted.formUnion(host.providers(of: "harness." + need)) }
        }
        var definitions = selfSchemas(host)
        var seen = Set(selfTools)
        for entry in host.entries where wanted.contains(entry.id) && host.isActive(entry.id) {
            for definition in host.registrations.tools[entry.id]?.definitions ?? [] {
                guard let name = definition["name"] as? String, seen.insert(name).inserted else { continue }
                definitions.append(definition)
            }
        }
        return ToolList(definitions)
    }

    private static func selfSchemas(_ host: ComponentHost) -> [[String: Any]] {
        let options = routeOptions(host)
        let confirmed = HerdrTools.confirmedField
        let step: [String: Any] = [
            "type": "object",
            "properties": [
                "action": HerdrTools.str("A tool name of your controls, e.g. open_app"),
                "arguments": ["type": "object", "description": "That tool's arguments"] as [String: Any],
            ] as [String: Any],
            "required": ["action"],
        ]
        let change: [String: Any] = [
            "type": "object",
            "properties": [
                "op": ["type": "string", "enum": Proposal.Change.Op.allCases.map(\.rawValue),
                       "description": "set a field; append or removeValue a memory fact; addEntry or removeEntry a skill"]
                    as [String: Any],
                "path": HerdrTools.str("identity.name|role|personality|instructions, memory.facts, "
                    + "settings.voice|routeWithJev|jevModel, skill.<id> (addEntry, removeEntry) or skill.<id>.<field>"),
                "value": ["description": "The new value: text, true/false, a list, or a skill's config "
                    + "{title, summary, needs, steps, playbook}"] as [String: Any],
            ] as [String: Any],
            "required": ["op", "path"],
        ]
        var useSkill: [String: Any] = HerdrTools.str("A learned skill (skill.<id>) or a harness (harness.<name>)")
        if !options.isEmpty { useSkill["enum"] = options.map(\.id) }
        return [
            HerdrTools.fn("describe_self", "Who you are: your identity, what you remember, your settings, your harnesses "
                + "(and whether each works now) and the skills you learned.", [:], []),
            HerdrTools.fn("propose_change", "Propose a change to yourself: your identity, memory, voice or routing "
                + "settings, or your skills. Applies only after the user's own yes, even if they asked for it. You can't "
                + "change harnesses, the voice model or the confirmation rules.",
                ["summary": HerdrTools.str("What the change does, in one sentence"),
                 "changes": ["type": "array", "description": "Operations on your configuration, in order",
                             "items": change] as [String: Any],
                 "confirmed": confirmed], ["summary", "changes"]),
            HerdrTools.fn("learn_skill", "Learn a skill the user teaches you: steps (tool calls you'll repeat when they "
                + "ask for it by name) and/or a playbook (how to do the task, in your own words). Steps that always need "
                + "a spoken yes (closing, removing, shell, AppleScript, approvals) can't be learned. Saving needs the "
                + "user's yes.",
                ["title": HerdrTools.str("A short name the user will say, e.g. start my day"),
                 "summary": HerdrTools.str("What it does, in one sentence"),
                 "steps": ["type": "array", "description": "The tool calls to repeat, in order (at most 20)",
                           "items": step] as [String: Any],
                 "playbook": HerdrTools.str("How to do the task: what to check, in what order, what the user prefers"),
                 "confirmed": confirmed], ["title", "summary"]),
            HerdrTools.fn("forget_skill", "Forget a skill you learned. Needs the user's yes.",
                ["skill": HerdrTools.str("The skill, e.g. skill.start-my-day"), "confirmed": confirmed], ["skill"]),
            HerdrTools.fn("remember", "Remember a fact about the user or how they work, for every later session. "
                + "Needs the user's yes.",
                ["fact": HerdrTools.str("One sentence, e.g. Standup is at 10:00"), "confirmed": confirmed], ["fact"]),
            HerdrTools.fn("revert_change", "Undo a change to yourself, as list_changes names it. Needs the user's yes.",
                ["change": HerdrTools.str("The change's id, e.g. c3"), "confirmed": confirmed], ["change"]),
            HerdrTools.fn("list_changes", "List the latest changes to yourself, newest first.", [:], []),
            HerdrTools.fn("use_skill", "Load a learned skill or a harness's controls when the tools you have don't cover "
                + "what the user wants. For a skill you also get how to do it. Options: "
                + options.map { "\($0.id) (\($0.title))" }.joined(separator: "; "),
                ["skill": useSkill], ["skill"]),
        ]
    }

    /// Drops skills that are no longer active from the set in play (never touches the tree).
    private func pruneActive() {
        state.recentSkills = state.recentSkills.filter { state.host.isActive($0) }
    }

    /// The current emission. Call with the lock held.
    private func emission() -> RegistryEmission {
        RegistryEmission(tools: Self.activeTools(state), instructions: CompanionVoice.instructions(Self.profile(state.host)),
                         active: Self.active(state), tree: state.host.tree)
    }

    /// Hands an emission to the app's handler, outside the lock.
    private func emit(_ emission: RegistryEmission?) {
        guard let emission, let handler = lock.withLock({ state.onChange }) else { return }
        handler(emission)
    }

    private static func outcome(_ text: String) -> HerdrTools.Outcome {
        HerdrTools.Outcome(output: text, watch: nil)
    }
}
