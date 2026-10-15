import Foundation
import Testing
@testable import HerdrVoiceCore

private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
/// Milliseconds, to within what dates this far from 1970 can hold.
private func near(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 0.01 } ?? false }

private let responseDone = #"""
{"type":"response.done","response":{"id":"r1","status":"completed","usage":{"total_tokens":1700,"input_tokens":1200,
"output_tokens":500,"input_token_details":{"text_tokens":800,"audio_tokens":400,"image_tokens":0,"cached_tokens":600,
"cached_tokens_details":{"text_tokens":500,"audio_tokens":100,"image_tokens":0}},
"output_token_details":{"text_tokens":100,"audio_tokens":400}}}}
"""#

@Test func openAIUsageIsDecodedFromResponseDoneAndPricedByTheVersionedTable() throws {
    let usage = try #require(RealtimeUsage.fromResponseDone(responseDone))
    #expect(usage == RealtimeUsage(inputTextTokens: 800, inputAudioTokens: 400, cachedTextTokens: 500,
                                   cachedAudioTokens: 100, outputTextTokens: 100, outputAudioTokens: 400))
    #expect(usage.totalTokens == 1700)
    // 300 text in × $4 + 500 cached text × $0.40 + 300 audio in × $32 + 100 cached audio × $0.40
    // + 100 text out × $24 + 400 audio out × $64, per 1M tokens.
    let input: Double = 300 * 4 + 500 * 0.40 + 300 * 32 + 100 * 0.40
    let output: Double = 100 * 24 + 400 * 64
    let expected = (input + output) / 1_000_000
    #expect(abs(PriceTable.current.cost(usage, provider: .openai) - expected) < 1e-12)
    #expect(PriceTable.current.cost(usage, provider: .grok) == 0) // billed by the minute
    #expect(PriceTable.current.version == "2026-10-15")
}

@Test func cachedTokensWithoutTheirBreakdownStillPriceAtTheCachedRate() throws {
    let done = #"{"type":"response.done","response":{"usage":{"input_token_details":{"text_tokens":300,"#
        + #""audio_tokens":700,"cached_tokens":500},"output_token_details":{"text_tokens":0,"audio_tokens":100}}}}"#
    let usage = try #require(RealtimeUsage.fromResponseDone(done))
    #expect(usage.cachedTextTokens == 300 && usage.cachedAudioTokens == 200)
}

@Test func theOpenAIWireReportsUsageJustBeforeTheResponseEnds() {
    let wire = OpenAIRealtimeWire(provider: .openai)
    let events = wire.decode(responseDone)
    #expect(events.count == 2 && events.last == .responseDone)
    if case .usage(let usage)? = events.first { #expect(usage.outputAudioTokens == 400) } else { Issue.record("no usage") }
    // No usage, or xAI's: just the end of the response, as before.
    #expect(wire.decode(#"{"type":"response.done"}"#) == [.responseDone])
    #expect(OpenAIRealtimeWire(provider: .grok).decode(responseDone) == [.responseDone])
}

@Test func minuteBilledModelsArePricedByTimeAndGeminiIsAnEstimate() throws {
    let table = PriceTable.current
    #expect(abs(table.cost(connectedSeconds: 600, spokenSeconds: 0, provider: .grok) - 0.8) < 1e-9)
    #expect(abs(table.cost(connectedSeconds: 600, spokenSeconds: 120, provider: .gemini) - (10 * 0.005 + 2 * 0.018)) < 1e-9)
    #expect(table.row(.gemini)?.estimated == true && table.row(.grok)?.estimated == false)
    #expect(table.cost(connectedSeconds: 600, spokenSeconds: 600, provider: .local) == 0)
    #expect(try #require(table.row(.openai)).summary.contains("$32"))
}

@Test func aTurnRecordsItsLatencyBreakdownToolsQuestionsAndCost() throws {
    var ledger = TurnLedger(provider: .openai)
    let none = ledger.speechStarted(at: at(0))
    #expect(none == nil)
    ledger.speechEnded(at: at(2))
    let resumed = ledger.speechStarted(at: at(2.2))
    #expect(resumed == nil) // resumed in the cooldown: the same turn
    ledger.speechEnded(at: at(3))
    ledger.submitted(at: at(3.5))
    _ = ledger.userText("open safari please", typed: false, at: at(3.6))
    ledger.route(TurnRecord.Route(skill: "harness.mac", source: "jev", confidence: 0.92, milliseconds: 140))
    ledger.toolStarted("set_model", arguments: #"{"provider":"openai"}"#, at: at(3.8))
    ledger.toolFinished("set_model", output: "CONFIRMATION REQUIRED. Nothing was done yet.", at: at(3.9))
    ledger.toolStarted("set_model", arguments: #"{"provider":"openai","confirmed":true}"#, at: at(4))
    ledger.toolFinished("set_model", output: "Done: switching to GPT.", at: at(4.2))
    ledger.toolStarted("prompt_agent", arguments: #"{"target":"claude-2","text":"secret plan"}"#, at: at(4.3))
    ledger.toolFinished("prompt_agent", output: "sent; claude-2 is working", at: at(4.4))
    ledger.replyAudio(at: at(4.7))
    ledger.replyAudio(at: at(5))
    ledger.interrupted()
    ledger.usage(try #require(RealtimeUsage.fromResponseDone(responseDone)))
    let busy = ledger.tick(at: at(6), busy: true), quiet = ledger.tick(at: at(7), busy: false)
    #expect(busy == nil && quiet == nil)
    let settled = ledger.tick(at: at(8.6), busy: false)
    let turn = try #require(settled)
    #expect(near(turn.latencyMs, 1700) && near(turn.cooldownMs, 500) && near(turn.modelMs, 1200))
    #expect(turn.route?.source == "jev" && turn.userWords == 3)
    #expect(turn.tools.map(\.outcome) == [.confirmation, .ok, .ok])
    #expect(turn.confirmationsAsked == 1 && turn.confirmationsGiven == 1 && turn.interruptions == 1)
    #expect(turn.tools[2].delegation && turn.tools[2].target == "claude-2")
    #expect(turn.costUSD > 0 && !turn.costEstimated && turn.end == at(7))
    #expect(ledger.open == nil)
}

@Test func theNextTurnClosesTheLastAndMinuteBilledTurnsCarryAnEstimate() throws {
    var ledger = TurnLedger(provider: .grok)
    _ = ledger.speechStarted(at: at(0))
    ledger.replyAudio(at: at(2))
    let closed = ledger.speechStarted(at: at(32))
    let first = try #require(closed)
    #expect(first.costEstimated && abs(first.costUSD - 32.0 / 60 * 0.08) < 1e-9)
    let closedByTyping = ledger.userText("hello there", typed: true, at: at(40))
    let typed = try #require(closedByTyping)
    #expect(typed.tools.isEmpty && ledger.open?.typed == true && ledger.open?.speechEnd == at(40))
    let finished = ledger.finish(at: at(41))
    #expect(finished?.typed == true)
}

@Test func theDailyAggregateSumsTurnsAndKeepsNinetyDays() throws {
    var ledger = MetricsLedger()
    var turn = TurnRecord(id: "t", provider: "openai", model: "m", start: at(0), end: at(5))
    turn.speechEnd = at(1)
    turn.firstAudio = at(1.8)
    turn.tools = [TurnRecord.Tool(name: "prompt_agent", start: at(2), end: at(3), outcome: .ok, delegation: true)]
    turn.confirmationsAsked = 1
    turn.usage = RealtimeUsage(inputAudioTokens: 100, outputAudioTokens: 50)
    ledger.update(at(0)) { day in
        day.add(turn)
        day.add(turn)
        day.addCost(0.25, provider: "openai", estimated: false)
        day.addCost(0.10, provider: "gemini", estimated: true)
        day.userTalkSeconds += 12
    }
    let day = ledger.day(at(0))
    #expect(day.turns == 2 && day.actions == 2 && day.delegations == 2 && day.approvalsAsked == 2)
    #expect(near(day.averageLatencyMs, 800) && day.tokens["openai"] == 300)
    #expect(abs(day.totalCost - 0.35) < 1e-9 && day.costIsEstimated && day.estimated == ["gemini"])

    let week = ledger.lastDays(7, endingAt: at(86_400 * 3))
    #expect(week.count == 7 && week[3].metrics.turns == 2 && week.last?.metrics.turns == 0)

    ledger.update(at(-86_400 * 120)) { $0.turns = 9 }
    ledger.trim(before: at(0))
    #expect(ledger.days.count == 1)

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vox-metrics-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try ledger.save(url)
    #expect(MetricsLedger.load(url) == ledger)
    #expect(MetricsLedger.load(url.appendingPathExtension("missing")) == MetricsLedger())
}
