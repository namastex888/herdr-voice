import Foundation
import Testing
@testable import HerdrVoiceCore

@Test func jsonValuesKeepBooleansApartFromNumbers() throws {
    let text = #"{"a":true,"b":1,"c":null,"d":[1.5,"x"],"e":{"f":false}}"#
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    #expect(decoded == .object(["a": .bool(true), "b": .number(1), "c": .null, "d": .array([.number(1.5), .string("x")]),
                                "e": .object(["f": .bool(false)])]))
    let parsed = try #require(JSONValue(any: try JSONSerialization.jsonObject(with: Data(text.utf8))))
    #expect(parsed == decoded)
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded)) == decoded)
    #expect(JSONValue.object(["b": .number(2), "a": .string("x")]).canonical == #"{"a":"x","b":2}"#)
}

@Test func theTreeRoundTripsAndWritesDisabledOnlyWhenTrue() throws {
    let data = try JSONEncoder().encode(ConfigTree.factory)
    #expect(try JSONDecoder().decode(ConfigTree.self, from: data) == .factory)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.components(separatedBy: "\"disabled\"").count == 2)      // only the shell's
    let handWritten = #"{"version":1,"entries":[{"id":"x","kind":"gadget"}]}"#
    let tree = try JSONDecoder().decode(ConfigTree.self, from: Data(handWritten.utf8))
    #expect(tree.entries == [ConfigEntry(id: "x", kind: ComponentKind(rawValue: "gadget"))])
}

@Test func resettingToANewHireKeepsWhatTheHumanOwns() {
    var tree = ConfigTree.factory
    tree.entries.append(skillEntry("tidy"))
    tree["harness.shell"]?.disabled = false
    tree["settings"]?.config["provider"] = .string("openai")
    tree["settings"]?.config["activation"] = .string("wakeWord")
    tree["settings"]?.config["followUpSeconds"] = .number(15)
    tree["settings"]?.config["voice"] = .string("ash")
    tree["memory"]?.config["facts"] = .array([.string("Standup is at 10")])
    let reset = tree.resetToNewHire()
    #expect(reset.skillEntries.isEmpty && reset["memory"] == ConfigTree.factory["memory"])
    #expect(reset["harness.shell"]?.disabled == false)
    #expect(reset["settings"]?.config["provider"] == .string("openai"))
    // How she listens is the human's too; her voice is factory again.
    #expect(reset["settings"]?.config["activation"] == .string("wakeWord"))
    #expect(reset["settings"]?.config["followUpSeconds"] == .number(15))
    #expect(reset["settings"]?.config["voice"] == .null)
}

/// Writes 0.1.0's state exactly as it kept it: UserDefaults keys, and one JSON file per learned skill.
private func write010Skill(_ directory: URL, id: String, title: String, steps: [(String, String)]) throws {
    let body: [String: Any] = [
        "actions": [String](), "harness": "learned", "id": id, "learned": true, "summary": "\(title) for the user.",
        "title": title, "steps": steps.map { ["action": $0.0, "arguments": $0.1] },
    ]
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("\(id).json"))
}

@Test func theFirstLaunchBuildsTheTreeFrom010sState() throws {
    let directory = tempDirectory("migration")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, cleanUp) = scratchDefaults()
    defer { cleanUp() }
    defaults.set("openai", forKey: "provider")
    defaults.set(true, forKey: "allowAppleScript")
    defaults.set(true, forKey: "allowShell")
    defaults.set(false, forKey: "routeWithJev")
    defaults.set("jev-1.13.0", forKey: "jevModel")
    let store = CompanionStore(directory: directory)
    let skills = store.legacySkillsDirectory
    try write010Skill(skills, id: "start-my-day", title: "Start my day",
                      steps: [("open_app", #"{"name":"Mail"}"#), ("set_volume", #"{"percent":30}"#)])
    try write010Skill(skills, id: "check-agents", title: "Check agents", steps: [("list_agents", "{}"), ("open_app", "{}")])
    try Data("not json".utf8).write(to: skills.appendingPathComponent("broken.json"))
    try Data("{}".utf8).write(to: skills.appendingPathComponent("notes.txt"))

    let fakes = FakeHarnesses()
    let tree = store.loadTree(legacyDefaults: defaults, factory: fakes.factory)
    #expect(tree["harness.mac"]?.config["appleScript"] == .bool(true))
    #expect(tree["harness.shell"]?.disabled == false)
    #expect(tree["settings"]?.config["provider"] == .string("openai"))
    #expect(tree["settings"]?.config["routeWithJev"] == .bool(false))
    #expect(tree["settings"]?.config["jevModel"] == .string("jev-1.13.0"))
    #expect(tree.skillEntries.map(\.id) == ["skill.check-agents", "skill.start-my-day"])
    let start = try Skill(entry: try #require(tree["skill.start-my-day"]))
    #expect(start.title == "Start my day" && start.needs == ["mac"])
    #expect(start.steps == [.init(action: "open_app", arguments: #"{"name":"Mail"}"#),
                            .init(action: "set_volume", arguments: #"{"percent":30}"#)])
    #expect(try Skill(entry: try #require(tree["skill.check-agents"])).needs == ["herdr", "mac"])

    // Written once, the old files left in place; the next launch reads config.json and migrates nothing again.
    #expect(try JSONDecoder().decode(ConfigTree.self, from: Data(contentsOf: store.configFile)) == tree)
    #expect(FileManager.default.fileExists(atPath: skills.appendingPathComponent("start-my-day.json").path))
    try write010Skill(skills, id: "late", title: "Late", steps: [("open_app", "{}")])
    defaults.set(false, forKey: "allowShell")
    #expect(store.loadTree(legacyDefaults: defaults, factory: fakes.factory) == tree)

    // And the migrated skills run.
    let registry = SkillRegistry(store: store, factory: fakes.factory, gate: ConfirmGate(minDelay: 0, wait: 0.2))
    #expect(registry.status(of: "skill.start-my-day") == .active && registry.status(of: "skill.check-agents") == .active)
}

@Test func anUnreadableConfigIsMovedAsideNotOverwritten() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CompanionStore(directory: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{ half a tree".utf8).write(to: store.configFile)
    #expect(store.loadTree(legacyDefaults: nil, factory: FakeHarnesses().factory) == .factory)
    let aside = directory.appendingPathComponent("config.unreadable.json")
    #expect(try String(contentsOf: aside, encoding: .utf8) == "{ half a tree")
}

@Test func growthMetricsAndTheChangeLogLiveBesideTheTree() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CompanionStore(directory: directory)
    var metrics = GrowthMetrics()
    metrics.replays = 3
    try store.saveMetrics(metrics)
    #expect(store.loadMetrics() == metrics)
    let record = ChangeRecord(id: "c1", summary: "s", before: .factory, after: .factory, time: Date(timeIntervalSince1970: 1_000),
                              by: .user)
    try store.saveChanges([record])
    #expect(store.loadChanges() == [record])
    #expect(!FileManager.default.fileExists(atPath: store.configFile.path))   // neither lives in the tree
}
