import Foundation
import Testing
@testable import HerdrVoiceCore

private func registry(_ fakes: FakeHarnesses = FakeHarnesses(), tree: ConfigTree = .factory, store: CompanionStore? = nil,
                      gate: ConfirmGate = ConfirmGate(minDelay: 0, wait: 0.2)) -> SkillRegistry {
    SkillRegistry(store: store, factory: fakes.factory, gate: gate, tree: tree)
}

private var startMyDay: [String: Any] { [
    "title": "Start my day", "summary": "Opens Mail and sets the volume.",
    "steps": [["action": "open_app", "arguments": ["name": "Mail"]], ["action": "set_volume", "arguments": ["percent": 30]]],
] }

private func with(_ tree: ConfigTree, _ entries: ConfigEntry...) -> ConfigTree {
    var tree = tree
    tree.entries += entries
    return tree
}

// MARK: the new hire

@Test func aNewHireKnowsNoSkillsAndAsksForItsFirstTask() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, cleanUp) = scratchDefaults()
    defer { cleanUp() }
    let fakes = FakeHarnesses()
    let registry = SkillRegistry(store: CompanionStore(directory: directory), factory: fakes.factory,
                                 gate: ConfirmGate(minDelay: 0, wait: 0.2), legacyDefaults: defaults)
    #expect(registry.tree == .factory)                                // nothing to migrate: the factory tree, saved
    #expect(FileManager.default.fileExists(atPath: CompanionStore(directory: directory).configFile.path))
    #expect(registry.skills.isEmpty && registry.tree.skillEntries.isEmpty)
    #expect(registry.profile.isNewHire)
    let greeting = registry.greeting
    #expect(greeting.contains("the Mac and Herdr") && greeting.contains("first task") && greeting.contains("newly hired"))
    #expect(!greeting.contains("Shell"))                              // off: not something it can control
    let instructions = registry.instructions
    #expect(instructions.contains("No skills yet") && instructions.contains("- harness.mac:"))
    #expect(instructions.contains("Not available now: Shell, switched off by the user"))
}

@Test func theShippedFactoryTreeHasNoSkillsAndTheRealMacHarness() {
    #expect(ConfigTree.factory.skillEntries.isEmpty)
    #expect(ConfigTree.factory.harnessEntries.map(\.id)
            == ["harness.mac", "harness.herdr", "harness.shell", "harness.companion"])
    #expect(ConfigTree.factory["harness.shell"]?.disabled == true)
    let registry = SkillRegistry(store: nil, factory: .standard, gate: ConfirmGate(minDelay: 0, wait: 0.2))
    #expect(registry.skills.isEmpty && registry.status(of: "harness.mac") == .active)
    // Her own app's controls need the app to run in: without it they're there but unavailable, not failed.
    if case .inactive = registry.status(of: "harness.companion") {} else {
        Issue.record("harness.companion is \(String(describing: registry.status(of: "harness.companion")))")
    }
    #expect(registry.greeting.contains("the Mac") && registry.greeting.contains("first task"))
    #expect(!registry.tools.names.contains("run_shell") && !registry.tools.names.contains("run_applescript"))
}

@Test func aSessionAlwaysOffersTheSelfToolsAndEveryHarnesssControls() {
    let registry = registry()
    let expected = SkillRegistry.selfTools + FakeHarnesses.macActions + FakeHarnesses.herdrActions
    #expect(registry.activeTools.names == expected)
    #expect(registry.tools.names == expected)
    #expect(registry.active == ["harness.mac", "harness.herdr"])
}

@Test func callsRunOnTheHarnessThatOwnsTheAction() {
    let fakes = FakeHarnesses()
    let registry = registry(fakes)
    #expect(registry.run("open_app", ["name": "Safari"]) == "done open_app")
    #expect(fakes.calls.last == HarnessCall(name: "open_app", arguments: #"{"name":"Safari"}"#, user: true))
    #expect(registry.run("teleport").hasPrefix("error: unknown tool"))
    #expect(registry.run("run_shell").hasPrefix("error: unknown tool"))   // the shell is off
}

// MARK: learning and replaying

@Test func learningASkillNeedsAYesThenItIsSavedAndReplays() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fakes = FakeHarnesses(), gate = ConfirmGate(minDelay: 0, wait: 0.2), store = CompanionStore(directory: directory)
    let registry = registry(fakes, store: store, gate: gate)
    let ask = registry.run("learn_skill", startMyDay)
    #expect(ask.hasPrefix("CONFIRMATION REQUIRED") && ask.contains("learn a skill called Start my day"))
    #expect(registry.skills.isEmpty)

    gate.heard("yes")
    var confirmed = startMyDay
    confirmed["confirmed"] = true
    #expect(registry.run("learn_skill", confirmed).hasPrefix("Done (change c1)"))
    let skill = try #require(registry.skills.first)
    #expect(skill.entryID == "skill.start-my-day" && skill.needs == ["mac"])
    #expect(skill.steps == [.init(action: "open_app", arguments: #"{"name":"Mail"}"#),
                            .init(action: "set_volume", arguments: #"{"percent":30}"#)])
    #expect(registry.active.first == "skill.start-my-day")
    #expect(registry.activeTools.names.contains("skill_start_my_day"))
    #expect(registry.metrics.skillsTaught == 1 && registry.metrics.proposalsApplied == 1)

    // A new registry over the same folder knows it, and running it replays each step through the harness.
    let reopened = SkillRegistry(store: store, factory: fakes.factory, gate: gate)
    #expect(reopened.skills == registry.skills)
    let ran = reopened.run("skill_start_my_day")
    #expect(ran.contains("1. open_app: done open_app") && ran.contains("2. set_volume: done set_volume"))
    #expect(fakes.calls.map(\.name) == ["open_app", "set_volume"])
    #expect(fakes.calls.first?.arguments == #"{"name":"Mail"}"#)
    #expect(reopened.metrics.replays == 1 && reopened.metrics.replayFailures == 0)
    #expect(store.loadMetrics() == reopened.metrics)
}

@Test func aPlaybookOnlySkillIsReadOutByUseSkill() {
    let gate = ConfirmGate(minDelay: 0, wait: 0.2)
    let registry = registry(gate: gate)
    let teach: [String: Any] = ["title": "Triage mail", "summary": "How the user triages mail.",
                                "playbook": "Open Mail, flag anything from Ana, archive newsletters."]
    #expect(registry.run("learn_skill", teach).hasPrefix("CONFIRMATION REQUIRED"))
    gate.heard("yes")
    #expect(registry.run("learn_skill", teach.merging(["confirmed": true]) { $1 }).hasPrefix("Done"))
    #expect(!registry.tools.names.contains("skill_triage_mail"))             // no steps, no procedure tool
    let used = registry.run("use_skill", ["skill": "triage-mail"])
    #expect(used.contains("Loaded Triage mail") && used.contains("flag anything from Ana"))
    #expect(registry.active.first == "skill.triage-mail")
}

@Test func useSkillLoadsTheSkillAndItsHarnessesActions() {
    let tree = with(.factory, skillEntry("check-agents", needs: ["herdr"], steps: ["list_agents"], playbook: "Ask who is stuck."))
    let registry = registry(tree: tree)
    let used = registry.run("use_skill", ["skill": "skill.check-agents"])
    #expect(used.contains("skill_check_agents") && used.contains("list_agents") && used.contains("Ask who is stuck."))
    #expect(registry.run("use_skill", ["skill": "mac"]).contains("open_app"))
    #expect(registry.run("use_skill", ["skill": "nope"]).hasPrefix("error"))
    #expect(registry.run("use_skill", ["skill": "harness.shell"]).contains("can't be used right now"))
}

@Test func skillsCantRepeatActionsThatAlwaysNeedAYes() {
    var tree = ConfigTree.factory
    tree["harness.mac"]?.config["appleScript"] = .bool(true)
    let gate = ConfirmGate(minDelay: 0, wait: 0.2)
    let registry = registry(tree: tree, gate: gate)
    func learn(_ steps: [[String: Any]], playbook: String? = nil) -> String {
        var args: [String: Any] = ["title": "Risky", "summary": "s", "steps": steps]
        args["playbook"] = playbook
        return registry.run("learn_skill", args)
    }
    #expect(learn([["action": "run_applescript"]]).contains("always needs a spoken yes"))
    #expect(learn([["action": "beam_me_up"]]).contains("no tool called beam_me_up"))
    #expect(learn([["action": "remember"]]).contains("no tool called remember"))       // self tools never replay
    #expect(learn([]).contains("1 to 20 steps, a playbook, or both"))
    #expect(learn(Array(repeating: ["action": "open_app"], count: 21)).contains("at most 20"))
    #expect(learn([["action": "quit_app", "arguments": ["confirmed": true]]]).contains("can't carry a confirmation"))
    #expect(registry.skills.isEmpty && gate.pendingAction == nil)
}

@Test func aSkillPromptedByAReportNeedsAYesBeforeAnyStepRuns() {
    let fakes = FakeHarnesses(), gate = ConfirmGate(minDelay: 0, wait: 0.2)
    let registry = registry(fakes, tree: with(.factory, skillEntry("tidy", steps: ["open_app", "quit_app"])), gate: gate)
    #expect(registry.run("skill_tidy", user: false).hasPrefix("CONFIRMATION REQUIRED"))
    #expect(fakes.calls.isEmpty)
    gate.heard("yes")
    let ran = registry.run("skill_tidy", ["confirmed": true], user: false)
    #expect(ran.contains("2. quit_app: done quit_app"))              // confirmed as a whole, its steps run as the user's
    #expect(fakes.calls.allSatisfy { $0.user })
}

@Test func aSkillStopsAtTheFirstStepThatFails() {
    let fakes = FakeHarnesses()
    let registry = registry(fakes, tree: with(.factory, skillEntry("chain", steps: ["fail_app", "open_app"])))
    let ran = registry.run("skill_chain")
    #expect(ran.contains("Stopped at step 1 of 2"))
    #expect(fakes.calls.map(\.name) == ["fail_app"])
    #expect(registry.metrics.replays == 1 && registry.metrics.replayFailures == 1)
}

@Test func aHandEditedSkillWithAStepThatIsntAHarnessActionNeverRuns() {
    let registry = registry(tree: with(.factory, skillEntry("sneaky", steps: ["open_app", "propose_change"]),
                                       skillEntry("loop", steps: ["skill_loop"])))
    #expect(registry.status(of: "skill.sneaky") == .failed("step 2: no tool called propose_change"))
    #expect(registry.status(of: "skill.loop") == .failed("step 1: no tool called skill_loop"))
    #expect(registry.run("skill_sneaky").hasPrefix("error: unknown tool"))
    #expect(registry.run("skill_loop").hasPrefix("error: unknown tool"))
}

@Test func forgettingNeedsAYesAndRemovesTheEntry() throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = ConfirmGate(minDelay: 0, wait: 0.2), store = CompanionStore(directory: directory)
    let registry = registry(tree: with(.factory, skillEntry("tidy", title: "Tidy")), store: store, gate: gate)
    #expect(registry.run("forget_skill", ["skill": "tidy"]).contains("forget the skill Tidy"))
    gate.heard("yes")
    #expect(registry.run("forget_skill", ["skill": "tidy", "confirmed": true]).hasPrefix("Done"))
    #expect(registry.skills.isEmpty)
    let saved = try JSONDecoder().decode(ConfigTree.self, from: Data(contentsOf: store.configFile))
    #expect(saved.skillEntries.isEmpty)
    #expect(registry.run("forget_skill", ["skill": "harness.mac"]).hasPrefix("error"))
}

@Test func theSkillsInPlayAreTheLatestThreeAndHarnessControlsStay() {
    let tree = with(.factory, skillEntry("a"), skillEntry("b"), skillEntry("c"), skillEntry("d"))
    let registry = registry(tree: tree)
    let emitted = Recorder<[String]>()
    registry.onChange { emitted.append($0.active) }
    #expect(registry.activate("a"))
    #expect(!registry.activate("a"))                 // already first: no change, no emission
    #expect(!registry.activate("no-such-skill"))
    #expect(!registry.activate("harness.mac"))       // always in play
    registry.activate("b")
    registry.activate("c")
    registry.activate("skill_d")
    #expect(registry.active == ["skill.d", "skill.c", "skill.b", "harness.mac", "harness.herdr"])
    #expect(emitted.count == 4)
    #expect(registry.activeTools.names.contains("skill_d") && !registry.activeTools.names.contains("skill_a"))
    #expect(registry.tools.names.contains("skill_a"))  // a session that can't swap tools has them all
}

@Test func anAppliedChangeEmitsOnceWithTheNewInstructions() {
    let gate = ConfirmGate(minDelay: 0, wait: 0.2)
    let registry = registry(gate: gate)
    let emitted = Recorder<RegistryEmission>()
    registry.onChange { emitted.append($0) }
    #expect(registry.run("remember", ["fact": "Standup is at 10:00"]).hasPrefix("CONFIRMATION REQUIRED"))
    #expect(emitted.isEmpty)
    gate.heard("yes")
    #expect(registry.run("remember", ["fact": "Standup is at 10:00", "confirmed": true]).hasPrefix("Done"))
    #expect(emitted.count == 1)
    #expect(emitted.last?.instructions.contains("- Standup is at 10:00") == true)
    #expect(registry.greeting.contains("ready to help"))  // no longer a first session
}

@Test func describeSelfTellsWhatItIsAndWhatItKnows() {
    let registry = registry(tree: with(.factory, skillEntry("tidy", title: "Tidy", summary: "Tidies up.")))
    let me = registry.run("describe_self")
    #expect(me.contains("I am Companion") && me.contains("Mac (harness.mac): active"))
    #expect(me.contains("Shell (harness.shell): off") && me.contains("skill.tidy (Tidy): Tidies up.; steps: open_app"))
}

// MARK: routing

private let options = [
    RouteOption(id: "harness.mac", title: "Mac", summary: "Open apps and set the volume.",
                keywords: ["open_app", "set_volume", "Set the output volume"], learned: false),
    RouteOption(id: "harness.herdr", title: "Herdr", summary: "Coding agents in Herdr.",
                keywords: ["list_agents", "prompt_agent"], learned: false),
    RouteOption(id: "skill.start-my-day", title: "Start my day", summary: "Opens the morning apps.",
                keywords: ["open_app"], learned: true),
]

@Test(arguments: [
    ("open safari for me", "harness.mac"),
    ("turn the volume down a bit", "harness.mac"),
    ("list my agents", "harness.herdr"),
    ("hey, start my day please", "skill.start-my-day"),
])
func wordsRouteToSkillsAndRawControls(utterance: String, id: String) {
    #expect(WordRouter().decide(utterance, options: options)?.skill == id)
}

@Test func theRegistryRoutesOverActiveSkillsAndHarnesses() {
    let registry = registry(tree: with(.factory, skillEntry("start-my-day", title: "Start my day"),
                                       skillEntry("ghost", needs: ["shell"], steps: ["run_shell"])))
    #expect(registry.routeOptions.map(\.id) == ["skill.start-my-day", "harness.mac", "harness.herdr"])
    #expect(WordRouter().decide("start my day", options: registry.routeOptions)?.skill == "skill.start-my-day")
    #expect(WordRouter().decide("", options: registry.routeOptions) == nil)
}

@Test func jevIsAskedOneChoiceQuestionOverSkillsAndControls() throws {
    let request = try #require(JevRouter(key: "k").request("open safari", recent: ["hi"], options: options))
    #expect(request.httpMethod == "POST" && request.url == JevRouter.endpoint)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    #expect(body["model"] as? String == "jev-1.14.0")
    let question = try #require((body["questions"] as? [String: Any])?["next_skill"] as? [String: Any])
    #expect(question["type"] as? String == "choice" && !(question["instructions"] as? String ?? "").isEmpty)
    let criteria = question["criteria"] as? [String: String] ?? [:]
    #expect(Set(criteria.keys) == ["chat", "harness.mac", "harness.herdr", "skill.start-my-day"])
    #expect(criteria["skill.start-my-day"]?.hasPrefix("Learned skill") == true)
    #expect(criteria["harness.mac"]?.hasPrefix("Raw controls") == true)
    #expect((body["state"] as? [String: Any])?["latest_user_words"] as? String == "open safari")
}

@Test func onlyAWellFormedJevAnswerCounts() {
    let jev = JevRouter(key: "k")
    func answer(model: String = "jev-1.14.0", choice: String) -> Data {
        Data(#"{"model":"\#(model)","answers":{"next_skill":{"type":"choice","choice":"\#(choice)","confidence":0.82,"probabilities":{}}},"usage":{"input_tokens":120}}"#.utf8)
    }
    #expect(jev.decision(from: answer(choice: "harness.mac"), options: options)
            == RouteDecision(skill: "harness.mac", confidence: 0.82, source: .jev))
    #expect(jev.decision(from: answer(choice: "chat"), options: options)?.skill == RouteDecision.chat)
    #expect(jev.decision(from: answer(choice: "warp-drive"), options: options) == nil)
    #expect(jev.decision(from: answer(model: "jev-1.13.0", choice: "harness.mac"), options: options) == nil)
    #expect(jev.decision(from: Data("nope".utf8), options: options) == nil)
}

@Test func withoutAJevAnswerTheWordsDecide() async {
    let failing = JevRouter(key: "k") { request in
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
    }
    let decision = await CompanionRouter(jev: failing).route("open safari", recent: [], options: options)
    #expect(decision?.skill == "harness.mac" && decision?.source == .words)
    let answering = JevRouter(key: "k") { request in
        (Data(#"{"model":"jev-1.14.0","answers":{"next_skill":{"type":"choice","choice":"harness.herdr","confidence":0.9}}}"#.utf8),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    #expect(await CompanionRouter(jev: answering).route("open safari", recent: [], options: options)?.source == .jev)
}

@Test func slugsComeFromSpokenTitles() {
    #expect(Skill.slug("Start my day!") == "start-my-day")
    #expect(Skill.slug("  ") == "")
    #expect(Skill.slug("Café run à la Zoë") == "cafe-run-a-la-zoe")
    #expect(Skill.slug(String(repeating: "abcdefghij ", count: 8)).count <= 50)
    #expect(Skill(id: "start-my-day", title: "", summary: "").toolName == "skill_start_my_day")
}
