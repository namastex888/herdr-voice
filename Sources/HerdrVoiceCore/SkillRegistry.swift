import Foundation
import os

/// The master harness. It knows every harness and every skill, keeps which skills are in play, and is the
/// companion's `ToolHost`: it offers the skill tools plus the active skills' actions, and runs each call on the
/// harness that owns it. Learned procedures replay their steps through `call` too, so every step meets the same gates.
public final class SkillRegistry: ToolHost, @unchecked Sendable { // learned skills and the active set live under `state`
    /// Actions a learned procedure may not contain: they always need a spoken yes, which a replayed step can't carry.
    public static let unrepeatable: Set<String> = ["run_shell", "run_in_pane", "run_applescript", "close_workspace",
                                                   "close_tab", "close_pane", "remove_worktree", "answer_agent"]
    /// Routed skills that stay loaded: the latest and the ones just before it, so a follow-up still finds its tools.
    public static let activeLimit = 3
    public static let maxSteps = 20

    private struct State {
        var learned: [Skill]
        var active: [String] = []
        var onActiveChange: (@Sendable ([String]) -> Void)?
    }

    private let harnesses: [any Harness]
    private let store: SkillStore?
    private let gate: ConfirmGate
    private let state: OSAllocatedUnfairLock<State>

    /// `store` nil keeps learned skills in memory only (tests).
    public init(harnesses: [any Harness], store: SkillStore?, gate: ConfirmGate = .shared) {
        self.harnesses = harnesses
        self.store = store
        self.gate = gate
        state = OSAllocatedUnfairLock(initialState: State(learned: store?.load() ?? []))
    }

    // MARK: skills

    /// Harnesses that can work right now.
    public var availableHarnesses: [any Harness] { harnesses.filter(\.isAvailable) }

    /// Every skill usable now: built-ins whose harness is available, cut to the actions it offers, then learned ones.
    public var skills: [Skill] {
        let builtIn = Skill.builtIn.compactMap { skill -> Skill? in
            guard let harness = availableHarnesses.first(where: { $0.id == skill.harness }) else { return nil }
            let offered = Set(harness.actionNames)
            var cut = skill
            cut.actions = skill.actions.filter(offered.contains)
            return cut.actions.isEmpty ? nil : cut
        }
        return builtIn + state.withLock { $0.learned }
    }

    public var learned: [Skill] { state.withLock { $0.learned } }

    /// One line per skill, for the voice's instructions.
    public var catalog: String {
        skills.map { "- \($0.id): \($0.summary)" }.joined(separator: "\n")
    }

    // MARK: active skills

    public var active: [String] { state.withLock { $0.active } }

    /// Called (on any thread) whenever the active skills change, by routing or because the voice loaded one.
    public func onActiveChange(_ handler: @escaping @Sendable ([String]) -> Void) {
        state.withLock { $0.onActiveChange = handler }
    }

    /// Puts skill `id` first among the active ones, dropping the oldest past `activeLimit`. Unknown ids are ignored.
    @discardableResult
    public func activate(_ id: String) -> Bool {
        guard skills.contains(where: { $0.id == id }) else { return false }
        let (changed, active, notify) = state.withLock { s -> (Bool, [String], (@Sendable ([String]) -> Void)?) in
            let next = Array(([id] + s.active.filter { $0 != id }).prefix(Self.activeLimit))
            guard next != s.active else { return (false, next, nil) }
            s.active = next
            return (true, next, s.onActiveChange)
        }
        if changed { notify?(active) }
        return changed
    }

    // MARK: tools

    /// Every tool, for providers that can't change tools mid-session.
    public var tools: ToolList { toolList(for: skills.map(\.id)) }

    /// The skill tools plus the active skills' tools: what a session that routes per turn offers.
    public var activeTools: ToolList { toolList(for: active) }

    public func toolList(for ids: [String]) -> ToolList {
        let all = skills
        var definitions = coreSchemas(all)
        var seen = Set<String>()
        for skill in all where ids.contains(skill.id) {
            if skill.learned {
                definitions.append(procedureSchema(skill))
                continue
            }
            guard let harness = availableHarnesses.first(where: { $0.id == skill.harness }) else { continue }
            for definition in harness.actions.definitions {
                guard let name = definition["name"] as? String, skill.actions.contains(name),
                      seen.insert(name).inserted else { continue }
                definitions.append(definition)
            }
        }
        return ToolList(definitions)
    }

    public func call(_ name: String, arguments: String, userInitiated: Bool) -> HerdrTools.Outcome {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        switch name {
        case "use_skill": return Self.outcome(useSkill(args["skill"] as? String ?? ""))
        case "list_skills": return Self.outcome(listSkills())
        case "learn_skill": return Self.outcome(learnSkill(args))
        case "forget_skill": return Self.outcome(forgetSkill(args["skill"] as? String ?? "",
                                                             confirmed: args["confirmed"] as? Bool ?? false))
        default: break
        }
        if let skill = learned.first(where: { $0.toolName == name }) {
            return runProcedure(skill, confirmed: args["confirmed"] as? Bool ?? false, userInitiated: userInitiated)
        }
        guard let harness = availableHarnesses.first(where: { $0.actionNames.contains(name) }) else {
            return Self.outcome("error: unknown tool \(name)")
        }
        return harness.call(name, arguments: arguments, userInitiated: userInitiated)
    }

    public func settle(_ target: String, done: @escaping @Sendable (String) -> Void) {
        HerdrTools.settle(target, done: done)
    }

    public func watchPane(_ watch: HerdrTools.PaneWatch, done: @escaping @Sendable (String) -> Void) {
        HerdrTools.watchPane(watch, done: done)
    }

    // MARK: editing outside the voice

    /// Deletes a learned skill from the companion's own UI, which is the user's explicit act; no spoken yes needed.
    public func removeLearned(_ id: String) throws {
        try store?.delete(id)
        state.withLock { s in
            s.learned.removeAll { $0.id == id }
            s.active.removeAll { $0 == id }
        }
    }

    /// Re-reads learned skills from disk (after the files were edited by hand).
    public func reload() {
        guard let store else { return }
        let fresh = store.load()
        state.withLock { $0.learned = fresh }
    }

    // MARK: the skill tools

    private func coreSchemas(_ all: [Skill]) -> [[String: Any]] {
        let skillField: [String: Any] = ["type": "string", "enum": all.map(\.id), "description": "The skill's id"]
        let step: [String: Any] = [
            "type": "object",
            "properties": [
                "action": HerdrTools.str("A tool name, e.g. open_app"),
                "arguments": ["type": "object", "description": "That tool's arguments"] as [String: Any],
            ] as [String: Any],
            "required": ["action"],
        ]
        return [
            HerdrTools.fn("use_skill", "Load a skill's tools when the ones you have don't cover what the user wants. "
                + "Skills: " + all.map { "\($0.id) (\($0.summary))" }.joined(separator: "; "),
                ["skill": skillField], ["skill"]),
            HerdrTools.fn("list_skills", "List every skill you can use, what it does, and whether its tools are loaded.",
                [:], []),
            HerdrTools.fn("learn_skill", "Learn a new skill the user teaches you: a named procedure of tool calls you can "
                + "repeat on request (\"when I say start my day, open Mail and Calendar and set the volume to 30\"). "
                + "Steps that always need a spoken yes (closing, removing, shell, AppleScript, approvals) can't be learned. "
                + "Saving needs the user's spoken yes.",
                ["title": HerdrTools.str("A short name the user will say, e.g. start my day"),
                 "summary": HerdrTools.str("What it does, in one sentence"),
                 "steps": ["type": "array", "description": "The tool calls to repeat, in order", "items": step] as [String: Any],
                 "confirmed": HerdrTools.confirmedField],
                ["title", "summary", "steps"]),
            HerdrTools.fn("forget_skill", "Delete a skill you learned. Needs the user's spoken yes.",
                ["skill": skillField, "confirmed": HerdrTools.confirmedField], ["skill"]),
        ]
    }

    private func procedureSchema(_ skill: Skill) -> [String: Any] {
        let plan = skill.steps.map(\.action).joined(separator: ", ")
        return HerdrTools.fn(skill.toolName, "\(skill.title): \(skill.summary) (a skill you learned; runs \(plan))",
                             ["confirmed": HerdrTools.confirmedField], [])
    }

    private func useSkill(_ id: String) -> String {
        guard let skill = skills.first(where: { $0.id == id }) else {
            return "error: no skill \(id). Skills: " + skills.map(\.id).joined(separator: ", ")
        }
        activate(id)
        let tools = skill.learned ? [skill.toolName] : skill.actions
        return "Loaded \(skill.title). Its tools are ready: " + tools.joined(separator: ", ")
    }

    private func listSkills() -> String {
        let active = Set(self.active)
        return skills.map { skill in
            let kind = skill.learned ? "learned, \(skill.steps.count) steps" : skill.harness
            return "\(skill.id) (\(kind))\(active.contains(skill.id) ? " [loaded]" : ""): \(skill.summary)"
        }.joined(separator: "\n")
    }

    private func learnSkill(_ args: [String: Any]) -> String {
        let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (args["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let id = Skill.slug(title)
        guard !id.isEmpty, !summary.isEmpty else { return "error: a skill needs a title and a one-sentence summary" }
        guard !Skill.builtIn.contains(where: { $0.id == id }) else {
            return "error: \(id) is a built-in skill; pick another title"
        }
        let raw = args["steps"] as? [[String: Any]] ?? []
        guard (1...Self.maxSteps).contains(raw.count) else { return "error: a skill needs 1 to \(Self.maxSteps) steps" }
        var steps: [Skill.Step] = []
        for (index, step) in raw.enumerated() {
            let action = step["action"] as? String ?? ""
            guard !Self.unrepeatable.contains(action) else {
                return "error: step \(index + 1), \(action), always needs a spoken yes, so a skill can't repeat it"
            }
            guard availableHarnesses.contains(where: { $0.actionNames.contains(action) }) else {
                return "error: step \(index + 1): no tool called \(action)"
            }
            let arguments = step["arguments"] as? [String: Any] ?? [:]
            let data = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])) ?? Data("{}".utf8)
            steps.append(Skill.Step(action: action, arguments: String(decoding: data, as: UTF8.self)))
        }
        let plan = steps.map { "\($0.action) \($0.arguments)" }.joined(separator: "; ")
        if let stop = HerdrTools.confirmStep("learn_skill", action: "learn_skill:\(id):\(plan)",
                                             question: "save a skill called \(title) that runs \(plan)",
                                             confirmed: args["confirmed"] as? Bool ?? false, gate) {
            return stop
        }
        let skill = Skill(id: id, title: title, summary: summary, harness: "learned", steps: steps, learned: true)
        do { try store?.save(skill) } catch { return "error: couldn't save the skill: \(error.localizedDescription)" }
        state.withLock { s in
            s.learned.removeAll { $0.id == id }
            s.learned.append(skill)
        }
        activate(id)
        return "Learned \(title) (\(steps.count) steps). It runs whenever the user asks for it by name."
    }

    private func forgetSkill(_ id: String, confirmed: Bool) -> String {
        guard let skill = learned.first(where: { $0.id == id }) else {
            return "error: \(id) isn't a learned skill (built-in skills can't be forgotten)"
        }
        if let stop = HerdrTools.confirmStep("forget_skill", action: "forget_skill:\(id)",
                                             question: "forget the skill \(skill.title)", confirmed: confirmed, gate) {
            return stop
        }
        do { try removeLearned(id) } catch { return "error: couldn't delete it: \(error.localizedDescription)" }
        return "Forgot \(skill.title)."
    }

    /// Runs a learned skill's steps in order and stops at the first that doesn't go through. Run on the user's word,
    /// its steps count as the user's; prompted by a report instead, the whole skill first needs a spoken yes.
    private func runProcedure(_ skill: Skill, confirmed: Bool, userInitiated: Bool) -> HerdrTools.Outcome {
        if !userInitiated, let stop = HerdrTools.confirmStep(skill.toolName, action: skill.toolName,
                                                             question: "run your skill \(skill.title)",
                                                             confirmed: confirmed, gate) {
            return Self.outcome(stop)
        }
        var lines: [String] = []
        var watch: String?
        var paneWatch: HerdrTools.PaneWatch?
        for (index, step) in skill.steps.enumerated() {
            // A hand-edited file could carry one; the rule holds at run time too.
            let result = Self.unrepeatable.contains(step.action)
                ? Self.outcome("error: \(step.action) always needs a spoken yes, so a skill can't run it")
                : call(step.action, arguments: step.arguments, userInitiated: true)
            watch = watch ?? result.watch
            paneWatch = paneWatch ?? result.paneWatch
            lines.append("\(index + 1). \(step.action): \(result.output)")
            if ["error", "CONFIRMATION REQUIRED", "NOT DONE"].contains(where: result.output.hasPrefix) {
                lines.append("Stopped at step \(index + 1) of \(skill.steps.count).")
                break
            }
        }
        var outcome = HerdrTools.Outcome(output: "Ran \(skill.title):\n" + lines.joined(separator: "\n"), watch: watch)
        outcome.paneWatch = paneWatch
        return outcome
    }

    private static func outcome(_ text: String) -> HerdrTools.Outcome {
        HerdrTools.Outcome(output: text, watch: nil)
    }
}
