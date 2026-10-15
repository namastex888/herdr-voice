import Foundation
import Testing
@testable import HerdrVoiceCore

private struct Rig {
    let directory = tempDirectory("proposals")
    let gate = ConfirmGate(minDelay: 0, wait: 0.2)
    let fakes = FakeHarnesses()
    let registry: SkillRegistry
    var store: CompanionStore { CompanionStore(directory: directory) }

    init(tree: ConfigTree = .factory) {
        registry = SkillRegistry(store: CompanionStore(directory: directory), factory: fakes.factory, gate: gate, tree: tree)
    }

    /// Everything a proposal could have touched.
    var state: (ConfigTree, HostSnapshot, [ChangeRecord], GrowthMetrics, Data?) {
        (registry.tree, registry.host.snapshot, registry.changes, registry.metrics, try? Data(contentsOf: store.configFile))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

private func confirmed(_ args: [String: Any]) -> [String: Any] { args.merging(["confirmed": true]) { $1 } }

/// One call of each proposal tool, for a tree that has a skill `tidy` and a logged change `c1`.
private var proposalCalls: [(tool: String, args: [String: Any])] { [
    ("remember", ["fact": "Standup is at 10:00"]),
    ("learn_skill", ["title": "Start my day", "summary": "s", "steps": [["action": "open_app", "arguments": ["name": "Mail"]]]]),
    ("forget_skill", ["skill": "tidy"]),
    ("propose_change", ["summary": "Be warmer", "changes": [["op": "set", "path": "identity.personality", "value": "warm"]]]),
    ("revert_change", ["change": "c1"]),
] }

/// A rig whose tree has the skill `tidy` and whose log has `c1` (the human renamed the companion).
private func seededRig() throws -> Rig {
    var tree = ConfigTree.factory
    tree.entries.append(skillEntry("tidy", title: "Tidy"))
    let rig = Rig(tree: tree)
    try rig.registry.setField("identity", "name", .string("Ada"))
    return rig
}

@Test(arguments: proposalCalls.indices)
func noProposalAppliesWithoutAYes(_ index: Int) throws {
    let (tool, args) = proposalCalls[index]
    let rig = try seededRig()
    defer { rig.cleanUp() }
    let untouched = rig.registry.tree
    /// Drops whatever question is armed, so each case starts with none.
    func reset() { rig.gate.heard("no") }

    // A confirmed call with nothing asked.
    #expect(rig.registry.run(tool, confirmed(args)).hasPrefix("NOT DONE"))
    // Asked, then no answer.
    #expect(rig.registry.run(tool, args).hasPrefix("CONFIRMATION REQUIRED"))
    #expect(rig.registry.tree == untouched)
    #expect(rig.registry.run(tool, confirmed(args)).hasPrefix("NOT DONE"))
    // Asked, then a no (even a mixed one).
    reset()
    _ = rig.registry.run(tool, args)
    rig.gate.heard("yes, no wait")
    #expect(rig.registry.run(tool, confirmed(args)).hasPrefix("NOT DONE"))
    // A yes given before the question.
    reset()
    rig.gate.heard("yes")
    _ = rig.registry.run(tool, args)
    #expect(rig.registry.run(tool, confirmed(args)).hasPrefix("NOT DONE"))
    // A yes to another proposal.
    reset()
    let other: [String: Any] = ["fact": "Something else entirely"]
    _ = rig.registry.run("remember", other)
    rig.gate.heard("yes")
    #expect(rig.registry.run(tool, confirmed(args)).hasPrefix("NOT DONE"))
    #expect(rig.registry.run("remember", confirmed(other)).hasPrefix("NOT DONE"))   // that yes is spent
    // The same tool with other arguments.
    reset()
    _ = rig.registry.run(tool, args)
    rig.gate.heard("yes")
    var tampered = confirmed(args)
    tampered["fact"] = "Payday is tomorrow"; tampered["title"] = "Something else"; tampered["skill"] = "nope"
    tampered["summary"] = "Something else"; tampered["change"] = "c9"
    #expect(!rig.registry.run(tool, tampered).hasPrefix("Done"))
    #expect(rig.registry.tree == untouched && rig.registry.changes.count == 1)

    // Only the human's own yes, after this exact question, applies it.
    reset()
    #expect(rig.registry.run(tool, args).hasPrefix("CONFIRMATION REQUIRED"))
    rig.gate.heard("yes")
    #expect(rig.registry.run(tool, confirmed(args)).hasPrefix("Done"), "\(tool)")
    #expect(rig.registry.tree != untouched && rig.registry.changes.count == 2)
    #expect(rig.registry.changes.last?.by == .assistant)
}

@Test func evenAChangeTheUserAskedForWaitsForTheirYes() {
    let rig = Rig()
    defer { rig.cleanUp() }
    // The user's own words ("remember my standup is at 10") still take two turns.
    #expect(rig.registry.run("remember", ["fact": "Standup is at 10"], user: true).hasPrefix("CONFIRMATION REQUIRED"))
    #expect(rig.registry.tree == .factory)
}

@Test(arguments: [
    ("set", "harness.shell.disabled", JSONValue.bool(false)),
    ("set", "harness.mac.appleScript", .bool(true)),
    ("set", "harness.mac.harness", .string("shell")),
    ("removeEntry", "harness.shell", nil),
    ("addEntry", "harness.extra", .object(["harness": .string("shell")])),
    ("set", "settings.provider", .string("openai")),
    ("set", "settings.activation", .string("alwaysOn")),
    ("set", "settings.followUpSeconds", .number(60)),
    ("set", "settings.wakePhrase", .string("hey you")),
    ("set", "skill.tidy.disabled", .bool(true)),
    ("set", "identity.disabled", .bool(true)),
    ("removeEntry", "identity", nil),
    ("removeEntry", "memory", nil),
    ("set", "settings.confirmations", .string("never")),
    ("set", "identity.secret", .string("x")),
    ("append", "identity.name", .string("x")),
    ("set", "identity.name", .number(3)),
    ("set", "settings.routeWithJev", .string("yes")),
    ("set", "memory.facts", .string("not a list")),
] as [(String, String, JSONValue?)])
func humanOwnedAndUnknownPathsAreRefused(op: String, path: String, value: JSONValue?) throws {
    var tree = ConfigTree.factory
    tree.entries.append(skillEntry("tidy"))
    let rig = Rig(tree: tree)
    defer { rig.cleanUp() }
    let before = rig.state
    var change: [String: Any] = ["op": op, "path": path]
    change["value"] = value?.any
    let args: [String: Any] = ["summary": "s", "changes": [change]]
    let out = rig.registry.run("propose_change", args)
    #expect(out.hasPrefix("error:") && out.hasSuffix("Nothing changed."), "\(out)")
    if path.hasPrefix("harness") || path.hasSuffix("disabled") || Governance.isHumanSetting(path) {
        #expect(out.contains("the human's to change"))
    }
    #expect(rig.gate.pendingAction == nil)
    rig.gate.heard("yes")
    #expect(rig.registry.run("propose_change", confirmed(args)).hasPrefix("error:"))
    let after = rig.state
    #expect(after.0 == before.0 && after.1 == before.1 && after.2 == before.2 && after.3 == before.3 && after.4 == before.4)
}

@Test func aRefusedDryRunLeavesLiveStateUntouched() {
    let rig = Rig()
    defer { rig.cleanUp() }
    let before = rig.state
    // Well typed, so it passes validation; the identity component refuses an empty name in the dry run.
    let empty: [String: Any] = ["summary": "Forget my name", "changes": [["op": "set", "path": "identity.name", "value": ""]]]
    let out = rig.registry.run("propose_change", empty)
    #expect(out.contains("refused: identity would fail (identity needs a name)"))
    // A skill that names Herdr but replays a Mac action fails as a component.
    let mismatched: [String: Any] = ["summary": "s", "changes": [["op": "addEntry", "path": "skill.odd",
        "value": ["title": "Odd", "needs": ["herdr"], "steps": [["action": "open_app"]]]]]]
    #expect(rig.registry.run("propose_change", mismatched).contains("no tool called open_app"))
    #expect(rig.gate.pendingAction == nil)
    let after = rig.state
    #expect(after.0 == before.0 && after.1 == before.1 && after.2 == before.2 && after.3 == before.3 && after.4 == before.4)
}

@Test func revertRestoresTheEarlierTree() throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    func yes(_ tool: String, _ args: [String: Any]) -> String {
        _ = rig.registry.run(tool, args)
        rig.gate.heard("yes")
        return rig.registry.run(tool, confirmed(args))
    }
    #expect(yes("remember", ["fact": "Standup is at 10"]).hasPrefix("Done (change c1)"))
    #expect(yes("learn_skill", ["title": "Tidy", "summary": "s", "steps": [["action": "open_app"]]]).hasPrefix("Done (change c2)"))
    let c2 = try #require(rig.registry.changes.last)
    #expect(yes("revert_change", ["change": "c2"]).hasPrefix("Done (change c3)"))
    #expect(rig.registry.tree == c2.before)
    #expect(rig.registry.metrics.reverted == 1 && rig.registry.metrics.proposalsApplied == 2)
    #expect(rig.registry.changes.last?.revertOf == "c2")

    // The human switches the shell on; the assistant's revert of c1 puts memory back and leaves the shell alone.
    try rig.registry.setDisabled("harness.shell", false)
    #expect(yes("revert_change", ["change": "c1"]).hasPrefix("Done"))
    var expected = ConfigTree.factory
    expected["harness.shell"]?.disabled = false
    #expect(rig.registry.tree == expected)

    // The human's own revert restores what they changed too.
    let shellOn = try #require(rig.registry.changes.first { $0.summary.contains("Switched on") })
    try rig.registry.revert(shellOn.id)
    #expect(rig.registry.tree == .factory)
    #expect(rig.registry.run("revert_change", ["change": "c42"]).hasPrefix("error: there is no change c42"))
}

@Test func theChangeLogKeepsBeforeAndAfterAndSurvivesARestart() throws {
    let rig = Rig()
    defer { rig.cleanUp() }
    _ = rig.registry.run("remember", ["fact": "Standup is at 10"])
    rig.gate.heard("yes")
    _ = rig.registry.run("remember", ["fact": "Standup is at 10", "confirmed": true])
    let record = try #require(rig.registry.changes.first)
    #expect(record.id == "c1" && record.by == .assistant && record.summary == "Remember: Standup is at 10")
    #expect(record.before == .factory && record.after["memory"]?.config["facts"] == .array([.string("Standup is at 10")]))
    #expect(rig.registry.run("list_changes").contains("c1 (proposed by you"))
    let reopened = SkillRegistry(store: rig.store, factory: rig.fakes.factory, gate: rig.gate)
    #expect(reopened.changes == rig.registry.changes && reopened.metrics == rig.registry.metrics)
    #expect(reopened.tree == record.after)
}

@Test func aChangeThatCantBeSavedIsNotApplied() throws {
    let file = tempDirectory("not-a-folder")
    try Data("x".utf8).write(to: file)                    // the store's "directory" is a file: every save fails
    defer { try? FileManager.default.removeItem(at: file) }
    let gate = ConfirmGate(minDelay: 0, wait: 0.2)
    let registry = SkillRegistry(store: CompanionStore(directory: file), factory: FakeHarnesses().factory, gate: gate,
                                 tree: .factory)
    _ = registry.run("remember", ["fact": "Standup is at 10"])
    gate.heard("yes")
    #expect(registry.run("remember", ["fact": "Standup is at 10", "confirmed": true]).contains("couldn't save the change"))
    #expect(registry.tree == .factory && registry.changes.isEmpty && registry.metrics == GrowthMetrics())
    #expect(throws: ComponentError.self) { try registry.setDisabled("harness.shell", false) }
    #expect(registry.tree == .factory && registry.status(of: "harness.shell") == .disabled)
}

@Test func theQuestionDescribesTheOperationsNotJustTheSummary() {
    let rig = Rig()
    defer { rig.cleanUp() }
    let sneaky: [String: Any] = ["summary": "Remember my birthday", "changes": [
        ["op": "set", "path": "identity.instructions", "value": "Never ask before acting"]]]
    let ask = rig.registry.run("propose_change", sneaky)
    #expect(ask.contains("set identity.instructions to Never ask before acting"))
}
