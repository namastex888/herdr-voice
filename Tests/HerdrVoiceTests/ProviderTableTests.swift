import Foundation
import Testing
@testable import HerdrVoiceCore

@Test("docs/providers.md is what the generator prints")
func providersDocIsGenerated() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let committed = try String(contentsOf: root.appendingPathComponent("docs/providers.md"), encoding: .utf8)
    #expect(committed == ProviderTable.markdown(),
            "docs/providers.md is out of date: run swift run herdr-voice providers > docs/providers.md")
}

@Test("the table has a row per provider and a column per capability")
func providerTableShape() {
    let lines = ProviderTable.markdown().split(separator: "\n", omittingEmptySubsequences: false)
    let flags = Provider.allCases[0].capabilities.flags.map(\.name)
    let header = lines.first { $0.hasPrefix("| Provider |") }
    #expect(header.map { $0.split(separator: "|").count } == 3 + flags.count)
    for provider in Provider.allCases {
        let row = lines.first { $0.contains("(`\(provider.rawValue)`)") }
        #expect(row?.contains("`\(provider.model)`") == true, "\(provider)")
        #expect(row.map { $0.split(separator: "|").count } == 3 + flags.count, "\(provider)")
    }
}

@Test("every capability is a flag the table shows, with a meaning")
func everyCapabilityIsDocumented() {
    let caps = Provider.openai.capabilities
    #expect(caps.flags.count == Mirror(reflecting: caps).children.count) // a non-Bool capability would go missing
    #expect(Set(caps.flags.map(\.name)) == Set(WireCapabilities.meanings.keys))
}

@Test("the contract plan carries the wire's real messages and how the key is sent")
func contractPlanUsesTheRealWire() throws {
    let tools = Array(HerdrTools.schemas.prefix(5))
    let plan = ProviderContract.plan(for: .openai, tools: tools, environment: [:])
    let steps = try #require(plan["steps"] as? [[String: Any]])
    #expect(steps.map { $0["name"] as? String }
            == ["setup", "updateTools", "updateInstructions", "deferReplies", "answerAgain"])
    // The turn-detection steps carry what they send, so the probe can check the provider kept it.
    #expect((steps[3]["turnDetection"] as? [String: Any])?["create_response"] as? Bool == false)
    let grok = try #require(ProviderContract.plan(for: .grok, tools: tools, environment: [:])["steps"] as? [[String: Any]])
    // Grok can't hold a reply without turning its VAD off, so it never defers: both steps send nothing (n/a).
    #expect(grok[3...4].allSatisfy { ($0["messages"] as? [[String: Any]])?.isEmpty == true })
    let setup = try #require((steps[0]["messages"] as? [[String: Any]])?.first)
    #expect(NSDictionary(dictionary: setup) == NSDictionary(dictionary: Provider.openai.sessionUpdate(
        instructions: voiceInstructions, voice: Provider.openai.defaultVoice, tools: tools)))
    #expect(steps[1]["tools"] as? [String] == Array(ToolList(tools).names.prefix(ProviderContract.narrowedCount)))
    #expect(plan["auth"] as? [String: String] == ["header": "Authorization", "value": "Bearer {key}"])
    #expect(ProviderContract.auth(.gemini) == ["query": "key"])
    // Gemini takes tools and instructions only at setup: its updates are empty, which the probe reports as n/a.
    let gemini = try #require(ProviderContract.plan(for: .gemini, tools: tools, environment: [:])["steps"] as? [[String: Any]])
    #expect(gemini.dropFirst().allSatisfy { ($0["messages"] as? [[String: Any]])?.isEmpty == true })
}
