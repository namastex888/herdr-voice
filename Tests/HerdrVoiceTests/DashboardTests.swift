import Foundation
import Testing
@testable import HerdrVoiceCore

/// Her app, faked: the dashboard's settings live in a real registry.
private final class DashboardApp: CompanionApp, @unchecked Sendable {
    weak var registry: SkillRegistry?
    var provider: Provider { .grok }
    var providers: [Provider] { [.grok, .openai, .gemini] }
    func perform(_ action: CompanionHarness.AppAction) -> String { "Done." }
}

private struct Rig {
    let app = DashboardApp()
    let gate = ConfirmGate(minDelay: 0, wait: 0)
    let registry: SkillRegistry

    init() {
        registry = SkillRegistry(store: nil, factory: .companion(app, gate: gate), gate: gate)
        app.registry = registry
    }

    var layout: DashboardLayout { DashboardLayout(registry.tree["settings"]?.config["dashboard"]) }
}

@Test func theCockpitStartsWithTheFourHeadlineWidgetsAndFourSections() {
    let layout = DashboardLayout(nil)
    #expect(layout.widgets == [.cost, .talk, .agents, .shipped])
    #expect(layout.sections == [.running, .recent, .week, .trend])
    #expect(DashboardLayout(layout.json) == layout)
    // Junk and duplicates in the setting are dropped, and a widget can't sit among the sections.
    let odd = DashboardLayout(.object(["widgets": .array([.string("talk"), .string("talk"), .string("nope")]),
                                       "sections": .array([.string("cost"), .string("week")])]))
    #expect(odd.widgets == [.talk] && odd.sections == [.week])
}

@Test func itemsAreFoundByIdTitleOrAFewWords() {
    #expect(DashboardItem.named("agentTime") == .agentTime)
    #expect(DashboardItem.named("agent time") == .agentTime)
    #expect(DashboardItem.named("the cost trend") == .trend)
    #expect(DashboardItem.named("Talk time") == .talk)
    #expect(DashboardItem.named("agents working") == .agents)
    #expect(DashboardItem.named("weather") == nil)
}

@Test func putAgentTimeOnTopAndHideCostTrendBySayingSo() throws {
    let rig = Rig()
    let changes = rig.registry.changes.count
    let top = rig.registry.run("set_dashboard", ["top": "agent time"])
    #expect(top.hasPrefix("Done: the cockpit shows widgets: Agent time, Cost today"))
    let hide = rig.registry.run("set_dashboard", ["hide": ["cost trend"]])
    #expect(hide.hasPrefix("Done"))
    #expect(rig.layout.widgets == [.agentTime, .cost, .talk, .agents, .shipped])
    #expect(rig.layout.sections == [.running, .recent, .week])
    // Applied at once, as the user's own edits by voice.
    #expect(rig.registry.changes.count == changes + 2)
    #expect(rig.registry.changes.last?.summary == "Dashboard changed (by voice)")
    _ = rig.registry.run("set_dashboard", ["widgets": ["latency", "cost"], "show": ["trend"]])
    #expect(rig.layout.widgets == [.latency, .cost] && rig.layout.sections.last == .trend)
}

@Test func aDashboardChangeTheUserDidntAskForWaitsForTheirYes() {
    let rig = Rig()
    let out = rig.registry.run("set_dashboard", ["hide": ["cost"]], user: false)
    #expect(out.hasPrefix("CONFIRMATION REQUIRED"))
    #expect(rig.layout == DashboardLayout())
}

@Test func aBadDashboardCallChangesNothingAndSaysWhy() {
    let rig = Rig()
    #expect(rig.registry.run("set_dashboard", ["hide": ["weather"]]).contains("no dashboard item called weather"))
    #expect(rig.registry.run("set_dashboard", ["widgets": ["running"]]).contains("sections go in sections"))
    #expect(rig.registry.run("set_dashboard", [:]).contains("say which widgets"))
    #expect(rig.layout == DashboardLayout())
}

@Test func theDashboardIsTheHumansSettingKeptByAResetAndNotProposable() throws {
    let rig = Rig()
    _ = rig.registry.run("set_dashboard", ["hide": ["shipped"]])
    let proposed = rig.registry.run("propose_change", ["summary": "s", "changes": [
        ["op": "set", "path": "settings.dashboard", "value": ["widgets": ["cost"]]]]])
    #expect(proposed.contains("is the human's to change"))
    let reset = rig.registry.tree.resetToNewHire()
    #expect(DashboardLayout(reset["settings"]?.config["dashboard"]).widgets == [.cost, .talk, .agents])
}

@Test func everyWidgetShowsItsBaseOrNotMeasured() {
    var day = DayMetrics()
    day.addCost(0.30, provider: "grok", estimated: false)
    day.conversations = 3
    day.userTalkSeconds = 90
    day.voxTalkSeconds = 150
    day.turns = 6
    day.latencyMsTotal = 2400
    day.latencyCount = 3
    day.approvalsAsked = 2
    day.approvalsGiven = 1
    #expect(WidgetReading.of(.cost, day: day, agents: nil) ==
            WidgetReading(value: "$0.300", base: "3 conversations · $0.100 each", measured: true))
    #expect(WidgetReading.of(.talk, day: day, agents: nil).value == "4m 0s")
    #expect(WidgetReading.of(.agents, day: day, agents: (2, 5)).base == "of 5 agents in Herdr")
    #expect(!WidgetReading.of(.agents, day: day, agents: nil).measured)
    #expect(WidgetReading.of(.shipped, day: day, agents: (2, 5)).base == "not measured until the Genie bridge")
    #expect(WidgetReading.of(.latency, day: day, agents: nil).value == "800 ms")
    #expect(WidgetReading.of(.latency, day: DayMetrics(), agents: nil).measured == false)
    #expect(WidgetReading.of(.approvals, day: day, agents: nil).value == "1/2")
    #expect(WidgetReading.series(.shipped) == nil)
    #expect(WidgetReading.series(.talk)?.value(day) == 4)
}

@Test func theDailyFileReadsFieldsItDidntWriteAsZero() throws {
    let old = #"{"cost":{"grok":0.5},"turns":3}"#
    let day = try JSONDecoder().decode(DayMetrics.self, from: Data(old.utf8))
    #expect(day.totalCost == 0.5 && day.turns == 3 && day.agentSeconds == 0 && day.estimated.isEmpty)
}

@Test func runningNowReadsTheHerdrHarnessesAgentList() throws {
    let herdr = #"{"id":"cli:agent:list","result":{"agents":[{"agent":"claude","agent_status":"working","cwd":"/r","#
        + #""name":"fix-login","terminal_title_stripped":"Fixing login"},{"agent":"codex","agent_status":"blocked","#
        + #""pane_id":"w1:p2","cwd":"/s"}]}}"#
    let agents = try #require(RunningAgent.parse(HerdrTools.trimAgents(herdr)))
    #expect(agents.map(\.target) == ["fix-login", "w1:p2"])
    #expect(agents[0].working && agents[0].title == "Fixing login" && agents[1].needsYou)
    #expect(RunningAgent.parse("error: unknown tool list_agents") == nil)
    #expect(RunningAgent.parse("[]") == [])
}
