import Foundation
import Testing
@testable import HerdrVoiceCore

/// Random edits of a tree, the way the human and accepted proposals make them: skills added, replaced and removed,
/// entries switched off and on, configs changed (some into ones that fail), harnesses added and removed.
private struct TreeEdits {
    static let skillIDs = ["skill.a", "skill.b", "skill.c", "skill.d", "skill.e"]
    static let needs = ["mac", "herdr", "shell", "ghost"]
    static let actions = ["open_app", "set_volume", "list_agents", "prompt_agent", "run_shell", "run_applescript", "teleport"]

    var rng: SplitMix64

    init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    mutating func pick<T>(_ items: [T]) -> T { items[Int(rng.next() % UInt64(items.count))] }
    mutating func coin() -> Bool { rng.next() % 2 == 0 }

    mutating func skill(_ id: String) -> ConfigEntry {
        let needs = Array(Set((0..<Int(rng.next() % 3)).map { _ in pick(Self.needs) })).sorted()
        let steps = (0..<Int(rng.next() % 4)).map { _ in pick(Self.actions) }
        return skillEntry(String(id.dropFirst("skill.".count)), summary: pick(["s1", "s2"]), needs: needs, steps: steps,
                          playbook: coin() ? "how to" : "")
    }

    mutating func edit(_ tree: inout ConfigTree) {
        switch rng.next() % 8 {
        case 0, 1:
            let id = pick(Self.skillIDs)
            tree[id] = skill(id)
        case 2:
            if let entry = tree.entries.isEmpty ? nil : pick(tree.entries) { tree[entry.id] = nil }
        case 3:
            if let entry = tree.entries.isEmpty ? nil : pick(tree.entries) { tree[entry.id]?.disabled.toggle() }
        case 4:
            if let entry = tree.skillEntries.isEmpty ? nil : pick(tree.skillEntries) {
                tree[entry.id]?.config["summary"] = .string(pick(["s1", "s2", "s3"]))
            }
        case 5:
            tree["harness.mac"]?.config["appleScript"] = .bool(coin())
        case 6:
            tree["identity"]?.config["name"] = .string(pick(["Companion", "Ada", ""]))   // "" fails
        default:
            if coin() {
                tree["harness.extra"] = ConfigEntry(id: "harness.extra", kind: .harness,
                                                    config: ["harness": .string(pick(["mac", "broken", "shell"]))])
            } else if let missing = ConfigTree.factory.entries.first(where: { tree[$0.id] == nil }) {
                tree.entries.append(missing)
            } else {
                tree["harness.extra"] = nil
            }
        }
    }
}

private func toolJSON(_ host: ComponentHost) -> String {
    let all = host.registrations.tools.keys.sorted().flatMap { host.registrations.tools[$0]!.definitions }
    return String(decoding: try! JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]), as: UTF8.self)
}

/// No skill is active while a harness it needs is off (Thm. 70–71).
private func orderingHolds(_ host: ComponentHost) -> Bool {
    host.entries.allSatisfy { entry in
        !host.isActive(entry.id) || ComponentHost.needs(of: entry).allSatisfy { !host.providers(of: $0).isEmpty }
    }
}

@Test func confluenceRandomEditsSettleWhereAFreshLoadDoes() {
    let fakes = FakeHarnesses()
    for seed in UInt64(0)..<60 {
        var edits = TreeEdits(seed: seed)
        var tree = ConfigTree.factory
        var live = ComponentHost(factory: fakes.factory)
        live.reconcile(tree)
        for _ in 0..<30 {
            edits.edit(&tree)
            live.reconcile(tree)
        }
        var fresh = ComponentHost(factory: fakes.factory)
        fresh.reconcile(tree)
        #expect(live.snapshot == fresh.snapshot, "seed \(seed)")
        #expect(toolJSON(live) == toolJSON(fresh), "seed \(seed)")
        #expect(live.registrations.skills == fresh.registrations.skills, "seed \(seed)")
        #expect(Set(live.registrations.harnesses.keys) == Set(fresh.registrations.harnesses.keys), "seed \(seed)")
    }
}

@Test func orderingHoldsAtEveryStepOfEveryReconcile() {
    let fakes = FakeHarnesses()
    var checkedSteps = 0
    for seed in UInt64(100)..<140 {
        var edits = TreeEdits(seed: seed)
        var tree = ConfigTree.factory
        var host = ComponentHost(factory: fakes.factory)
        for _ in 0..<30 {
            edits.edit(&tree)
            host.reconcile(tree) { step in
                checkedSteps += 1
                #expect(orderingHolds(step), "seed \(seed)")
            }
        }
    }
    #expect(checkedSteps > 500)
}

@Test func dependentsUnloadBeforeTheHarnessTheyNeed() {
    var tree = ConfigTree.factory
    tree.entries += [skillEntry("a", needs: ["mac"]), skillEntry("b", needs: ["herdr"], steps: ["list_agents"])]
    var host = ComponentHost(factory: FakeHarnesses().factory)
    host.reconcile(tree)
    #expect(host.isActive("skill.a") && host.isActive("skill.b"))
    tree["harness.mac"]?.disabled = true
    let off = host.reconcile(tree)
    #expect(off.unloaded == ["skill.a", "harness.mac"])
    #expect(host.status("skill.a") == .inactive("needs mac") && host.status("harness.mac") == .disabled)
    #expect(host.isActive("skill.b"))                                  // untouched
    tree["harness.mac"]?.config["appleScript"] = .bool(true)
    tree["harness.mac"]?.disabled = false
    let on = host.reconcile(tree)
    #expect(on.unloaded.isEmpty && on.loaded == ["harness.mac", "skill.a"])
}

@Test func aSkillWaitsInactiveUntilItsHarnessAppears() {
    let fakes = FakeHarnesses()
    fakes.herdrAvailable.value = false
    var tree = ConfigTree.factory
    tree.entries.append(skillEntry("agents", needs: ["herdr"], steps: ["list_agents"]))
    var host = ComponentHost(factory: fakes.factory)
    host.reconcile(tree)
    #expect(host.status("harness.herdr") == .inactive("Herdr isn't available on this Mac"))
    #expect(host.status("skill.agents") == .inactive("needs herdr"))
    fakes.herdrAvailable.value = true                                    // Herdr installed
    #expect(host.reconcile(tree).loaded == ["harness.herdr", "skill.agents"])
    fakes.herdrAvailable.value = false                                   // and gone again
    #expect(host.reconcile(tree).unloaded == ["skill.agents", "harness.herdr"])
    #expect(host.registrations.tools["skill.agents"] == nil)
}

@Test func recoveryLearningThenForgettingASkillLeavesNoTrace() {
    let fakes = FakeHarnesses()
    for seed in UInt64(200)..<230 {
        var edits = TreeEdits(seed: seed)
        var tree = ConfigTree.factory
        for _ in 0..<10 { edits.edit(&tree) }
        var host = ComponentHost(factory: fakes.factory)
        host.reconcile(tree)
        let before = host.snapshot, tools = toolJSON(host)
        var learned = tree
        learned.entries.append(skillEntry("fresh", needs: ["mac"], steps: ["open_app"], playbook: "notes"))
        host.reconcile(learned)
        host.reconcile(tree)
        #expect(host.snapshot == before && toolJSON(host) == tools, "seed \(seed)")
    }
}

@Test func recoveryThroughTheRegistryLeavesTheToolListAndCatalogIdentical() {
    let gate = ConfirmGate(minDelay: 0, wait: 0.2)
    let registry = SkillRegistry(store: nil, factory: FakeHarnesses().factory, gate: gate)
    func definitions() -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: registry.tools.definitions, options: [.sortedKeys]),
               as: UTF8.self)
    }
    let tools = definitions(), profile = registry.profile, instructions = registry.instructions
    let teach: [String: Any] = ["title": "Fresh", "summary": "s", "steps": [["action": "open_app"]]]
    _ = registry.run("learn_skill", teach)
    gate.heard("yes")
    #expect(registry.run("learn_skill", teach.merging(["confirmed": true]) { $1 }).hasPrefix("Done"))
    #expect(definitions() != tools)
    _ = registry.run("forget_skill", ["skill": "fresh"])
    gate.heard("yes")
    #expect(registry.run("forget_skill", ["skill": "fresh", "confirmed": true]).hasPrefix("Done"))
    #expect(definitions() == tools && registry.profile == profile && registry.instructions == instructions)
    #expect(registry.active == ["harness.mac", "harness.herdr"])
}

@Test func containmentAFailingEntryLeavesEveryOtherEntryAsItWas() {
    let fakes = FakeHarnesses()
    let failing: [ConfigEntry] = [
        skillEntry("boom", needs: ["mac"], steps: ["teleport"]),
        skillEntry("boom", needs: [], steps: []),                               // neither steps nor a playbook
        ConfigEntry(id: "harness.boom", kind: .harness, config: ["harness": .string("broken")]),
        ConfigEntry(id: "gadget", kind: ComponentKind(rawValue: "gadget")),
    ]
    for seed in UInt64(300)..<330 {
        var edits = TreeEdits(seed: seed)
        var tree = ConfigTree.factory
        for _ in 0..<12 { edits.edit(&tree) }
        var without = ComponentHost(factory: fakes.factory)
        without.reconcile(tree)
        for entry in failing {
            var withFailure = tree
            withFailure.entries.append(entry)
            var host = without
            host.reconcile(withFailure)
            if case .failed = host.status(entry.id) {} else if case .inactive = host.status(entry.id) {} else {
                Issue.record("seed \(seed): \(entry.id) should not run")
            }
            let others = Set(tree.entries.map(\.id))
            let base = without.snapshot, now = host.snapshot
            #expect(base.statuses.filter { others.contains($0.key) } == now.statuses.filter { others.contains($0.key) })
            #expect(base.tools == now.tools.filter { $0.key != entry.id }, "seed \(seed)")
            #expect(base.catalog == now.catalog.filter { $0.key != entry.id }, "seed \(seed)")
            #expect(base.published == now.published, "seed \(seed)")
            #expect(now.tools[entry.id] == nil && now.catalog[entry.id] == nil)   // rolled back, nothing registered
        }
    }
}

@Test func aFailedEntryIsNotRetriedUntilItsConfigChanges() {
    let fakes = FakeHarnesses()
    var tree = ConfigTree.factory
    tree.entries.append(ConfigEntry(id: "harness.boom", kind: .harness, config: ["harness": .string("broken")]))
    var host = ComponentHost(factory: fakes.factory)
    host.reconcile(tree)
    #expect(host.status("harness.boom") == .failed("this harness always breaks"))
    func attempts() -> Int { fakes.made.filter { $0 == "broken" }.count }
    #expect(attempts() == 1)
    tree["memory"]?.config["facts"] = .array([.string("unrelated")])
    #expect(host.reconcile(tree).changed)
    #expect(attempts() == 1)
    tree["harness.boom"]?.config["note"] = .string("try again")
    host.reconcile(tree)
    #expect(attempts() == 2)
}

@Test func aChangedConfigReloadsTheEntryAndAnUnchangedTreeIsANoOp() {
    var tree = ConfigTree.factory
    tree.entries.append(skillEntry("a", summary: "first"))
    var host = ComponentHost(factory: FakeHarnesses().factory)
    host.reconcile(tree)
    let again = host.reconcile(tree)
    #expect(!again.changed && again.loaded.isEmpty && again.unloaded.isEmpty)
    tree["skill.a"]?.config["summary"] = .string("second")
    let reload = host.reconcile(tree)
    #expect(reload.unloaded == ["skill.a"] && reload.loaded == ["skill.a"] && reload.changed)
    #expect(host.registrations.catalog["skill.a"]?.summary == "second")
}
