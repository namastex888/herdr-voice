import Foundation
import Testing
@testable import HerdrVoiceCore

/// A harness that records calls. `quit_app` needs a spoken yes unless the user asked; `fail_app` always errors.
private struct FakeHarness: Harness {
    let id: String
    var isAvailable = true
    let names: [String]
    let calls = Recorder<(name: String, arguments: String, user: Bool)>()
    var gate = ConfirmGate(minDelay: 0, wait: 0.2)

    var title: String { id }
    var actions: ToolList { ToolList(names.map { HerdrTools.fn($0, "does \($0)", [:], []) }) }

    func call(_ name: String, arguments: String, userInitiated: Bool) -> HerdrTools.Outcome {
        if name == "quit_app", !userInitiated,
           let stop = HerdrTools.confirmStep(name, action: name, question: "quit", confirmed: false, gate) {
            return HerdrTools.Outcome(output: stop, watch: nil)
        }
        calls.append((name, arguments, userInitiated))
        return HerdrTools.Outcome(output: name == "fail_app" ? "error: it failed" : "done \(name)", watch: nil)
    }
}

private func mac() -> FakeHarness {
    FakeHarness(id: "mac", names: ["open_app", "quit_app", "set_volume", "run_applescript", "fail_app"])
}

private func tempStore() -> SkillStore {
    SkillStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)"))
}

private func gate() -> ConfirmGate { ConfirmGate(minDelay: 0, wait: 0.2) }

private func args(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private var startMyDay: [String: Any] { [
    "title": "Start my day", "summary": "Opens Mail and sets the volume.",
    "steps": [["action": "open_app", "arguments": ["name": "Mail"]], ["action": "set_volume", "arguments": ["percent": 30]]],
] }

@Test func builtInSkillsFollowTheHarnessesThatAreHere() {
    let herdr = FakeHarness(id: "herdr", isAvailable: false, names: ["list_agents"])
    let registry = SkillRegistry(harnesses: [mac(), herdr], store: nil)
    let byID = Dictionary(uniqueKeysWithValues: registry.skills.map { ($0.id, $0) })
    #expect(byID["mac-apps"]?.actions == ["open_app", "quit_app"])        // cut to what the harness offers
    #expect(byID["mac-system"]?.actions == ["set_volume"])
    #expect(byID["herdr-agents"] == nil && byID["mac-shortcuts"] == nil)  // unavailable harness, no matching actions
}

@Test func aSessionOffersTheSkillToolsPlusTheActiveSkillsTools() {
    let registry = SkillRegistry(harnesses: [mac()], store: nil)
    let core = ["use_skill", "list_skills", "learn_skill", "forget_skill"]
    #expect(registry.activeTools.names == core)
    registry.activate("mac-apps")
    #expect(registry.activeTools.names == core + ["open_app", "quit_app"])
    #expect(Set(registry.tools.names).isSuperset(of: ["open_app", "set_volume", "run_applescript"]))
}

@Test func activationKeepsTheLatestThreeAndReportsEachChange() {
    let registry = SkillRegistry(harnesses: [mac(), FakeHarness(id: "shell", names: ["run_shell"])], store: nil)
    let changes = Recorder<[String]>()
    registry.onActiveChange { changes.append($0) }
    #expect(registry.activate("mac-apps"))
    #expect(!registry.activate("mac-apps"))       // already first: no change, no report
    #expect(!registry.activate("no-such-skill"))
    registry.activate("mac-system")
    registry.activate("mac-applescript")
    registry.activate("shell")
    #expect(registry.active == ["shell", "mac-applescript", "mac-system"])
    #expect(changes.count == 4)
}

@Test func callsRunOnTheHarnessThatOwnsTheAction() {
    let harness = mac()
    let registry = SkillRegistry(harnesses: [harness], store: nil)
    #expect(registry.call("open_app", arguments: #"{"name":"Safari"}"#, userInitiated: true).output == "done open_app")
    #expect(harness.calls.last?.arguments == #"{"name":"Safari"}"#)
    #expect(registry.call("teleport", arguments: "{}", userInitiated: true).output.hasPrefix("error: unknown tool"))
}

@Test func theVoiceCanLoadASkillItself() {
    let registry = SkillRegistry(harnesses: [mac()], store: nil)
    let out = registry.call("use_skill", arguments: #"{"skill":"mac-system"}"#, userInitiated: true).output
    #expect(out.contains("set_volume") && registry.active.first == "mac-system")
    #expect(registry.call("use_skill", arguments: #"{"skill":"nope"}"#, userInitiated: true).output.hasPrefix("error"))
    #expect(registry.call("list_skills", arguments: "{}", userInitiated: true).output.contains("mac-system (mac) [loaded]"))
}

@Test func learningASkillNeedsASpokenYesThenItIsSavedAndReplays() throws {
    let store = tempStore(), harness = mac(), g = gate()
    let registry = SkillRegistry(harnesses: [harness], store: store, gate: g)
    let ask = registry.call("learn_skill", arguments: args(startMyDay), userInitiated: true).output
    #expect(ask.hasPrefix("CONFIRMATION REQUIRED") && registry.learned.isEmpty && store.load().isEmpty)

    g.heard("yes")
    var confirmed = startMyDay
    confirmed["confirmed"] = true
    #expect(registry.call("learn_skill", arguments: args(confirmed), userInitiated: true).output.hasPrefix("Learned Start my day"))
    #expect(store.load().map(\.id) == ["start-my-day"])                       // on disk
    #expect(registry.active.first == "start-my-day")
    #expect(registry.activeTools.names.contains("skill_start_my_day"))

    // A new registry over the same folder knows it, and running it replays each step through the harness.
    let reopened = SkillRegistry(harnesses: [harness], store: store, gate: g)
    let ran = reopened.call("skill_start_my_day", arguments: "{}", userInitiated: true).output
    #expect(ran.contains("1. open_app: done open_app") && ran.contains("2. set_volume: done set_volume"))
    #expect(harness.calls.map(\.name) == ["open_app", "set_volume"])
    #expect(harness.calls.first?.arguments == #"{"name":"Mail"}"#)
}

@Test func skillsCantRepeatActionsThatAlwaysNeedAYes() {
    let registry = SkillRegistry(harnesses: [mac()], store: nil, gate: gate())
    func learn(_ steps: [[String: Any]], title: String = "Risky") -> String {
        registry.call("learn_skill", arguments: args(["title": title, "summary": "s", "steps": steps]), userInitiated: true).output
    }
    #expect(learn([["action": "run_applescript"]]).contains("always needs a spoken yes"))
    #expect(learn([["action": "beam_me_up"]]).contains("no tool called beam_me_up"))
    #expect(learn([]).contains("1 to 20 steps"))
    #expect(learn([["action": "open_app"]], title: "Mac apps").contains("built-in skill"))
    #expect(registry.learned.isEmpty)
}

@Test func aSkillPromptedByAReportNeedsAYesBeforeAnyStepRuns() throws {
    let harness = mac(), g = gate()
    let store = tempStore()
    try store.save(Skill(id: "tidy", title: "Tidy", summary: "s", harness: "learned",
                         steps: [.init(action: "open_app"), .init(action: "quit_app")], learned: true))
    let registry = SkillRegistry(harnesses: [harness], store: store, gate: g)
    #expect(registry.call("skill_tidy", arguments: "{}", userInitiated: false).output.hasPrefix("CONFIRMATION REQUIRED"))
    #expect(harness.calls.isEmpty)
    g.heard("yes")
    let ran = registry.call("skill_tidy", arguments: #"{"confirmed":true}"#, userInitiated: false).output
    #expect(ran.contains("2. quit_app: done quit_app"))            // confirmed as a whole, its steps run as the user's
    #expect(harness.calls.allSatisfy { $0.user })
}

@Test func aSkillStopsAtTheFirstStepThatFails() throws {
    let harness = mac(), store = tempStore()
    try store.save(Skill(id: "chain", title: "Chain", summary: "s", harness: "learned",
                         steps: [.init(action: "fail_app"), .init(action: "open_app"),
                                 .init(action: "run_applescript")], learned: true))
    let ran = SkillRegistry(harnesses: [harness], store: store).call("skill_chain", arguments: "{}", userInitiated: true).output
    #expect(ran.contains("Stopped at step 1 of 3"))
    #expect(harness.calls.map(\.name) == ["fail_app"])
}

@Test func forgettingNeedsAYesAndDeletesTheFile() throws {
    let store = tempStore(), g = gate()
    try store.save(Skill(id: "tidy", title: "Tidy", summary: "s", harness: "learned", steps: [.init(action: "open_app")],
                         learned: true))
    let registry = SkillRegistry(harnesses: [mac()], store: store, gate: g)
    #expect(registry.call("forget_skill", arguments: #"{"skill":"tidy"}"#, userInitiated: true).output.hasPrefix("CONFIRMATION"))
    g.heard("yes")
    #expect(registry.call("forget_skill", arguments: #"{"skill":"tidy","confirmed":true}"#, userInitiated: true).output == "Forgot Tidy.")
    #expect(store.load().isEmpty && registry.learned.isEmpty)
    #expect(registry.call("forget_skill", arguments: #"{"skill":"mac-apps"}"#, userInitiated: true).output.contains("built-in"))
}

@Test(arguments: [
    ("open safari for me", "mac-apps"),
    ("turn the volume down a bit", "mac-system"),
    ("run my shortcuts", "mac-shortcuts"),
])
func wordsRouteToTheSkillTheyName(utterance: String, skill: String) {
    let skills = SkillRegistry(harnesses: [FakeHarness(id: "mac", names: Skill.builtIn.filter { $0.harness == "mac" }
        .flatMap(\.actions))], store: nil).skills
    #expect(WordRouter().decide(utterance, skills: skills)?.skill == skill)
}

@Test func aLearnedSkillIsRoutedToByItsName() {
    let skills = Skill.builtIn + [Skill(id: "start-my-day", title: "Start my day", summary: "Opens the morning apps.",
                                        harness: "learned", learned: true)]
    #expect(WordRouter().decide("hey, start my day please", skills: skills)?.skill == "start-my-day")
    #expect(WordRouter().decide("", skills: skills) == nil)
}

@Test func jevIsAskedOneChoiceQuestionOverTheSkills() throws {
    let skills = Array(Skill.builtIn.prefix(2))
    let request = try #require(JevRouter(key: "k").request("open safari", recent: ["hi"], skills: skills))
    #expect(request.httpMethod == "POST" && request.url == JevRouter.endpoint)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    #expect(body["model"] as? String == "jev-1.14.0")
    let question = try #require((body["questions"] as? [String: Any])?["next_skill"] as? [String: Any])
    #expect(question["type"] as? String == "choice" && !(question["instructions"] as? String ?? "").isEmpty)
    #expect(Set((question["criteria"] as? [String: String] ?? [:]).keys) == ["chat", "mac-apps", "mac-system"])
    #expect((body["state"] as? [String: Any])?["latest_user_words"] as? String == "open safari")
}

@Test func onlyAWellFormedJevAnswerCounts() {
    let jev = JevRouter(key: "k"), skills = Skill.builtIn
    func answer(model: String = "jev-1.14.0", choice: String) -> Data {
        Data(#"{"model":"\#(model)","answers":{"next_skill":{"type":"choice","choice":"\#(choice)","confidence":0.82,"probabilities":{}}},"usage":{"input_tokens":120}}"#.utf8)
    }
    #expect(jev.decision(from: answer(choice: "mac-apps"), skills: skills)
            == RouteDecision(skill: "mac-apps", confidence: 0.82, source: .jev))
    #expect(jev.decision(from: answer(choice: "chat"), skills: skills)?.skill == RouteDecision.chat)
    #expect(jev.decision(from: answer(choice: "warp-drive"), skills: skills) == nil)
    #expect(jev.decision(from: answer(model: "jev-1.13.0", choice: "mac-apps"), skills: skills) == nil)
    #expect(jev.decision(from: Data("nope".utf8), skills: skills) == nil)
}

@Test func withoutAJevAnswerTheWordsDecide() async {
    let failing = JevRouter(key: "k") { request in
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
    }
    let decision = await CompanionRouter(jev: failing).route("open safari", recent: [], skills: Skill.builtIn)
    #expect(decision?.skill == "mac-apps" && decision?.source == .words)
    let answering = JevRouter(key: "k") { request in
        (Data(#"{"model":"jev-1.14.0","answers":{"next_skill":{"type":"choice","choice":"mac-system","confidence":0.9}}}"#.utf8),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    #expect(await CompanionRouter(jev: answering).route("open safari", recent: [], skills: Skill.builtIn)?.source == .jev)
}

@Test func slugsComeFromSpokenTitles() {
    #expect(Skill.slug("Start my day!") == "start-my-day")
    #expect(Skill.slug("  ") == "")
    #expect(Skill(id: "start-my-day", title: "", summary: "", harness: "learned").toolName == "skill_start_my_day")
}
