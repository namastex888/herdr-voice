import Foundation
import Testing
@testable import HerdrVoiceCore

// Provider parity, enforced: every wire runs the same scenario for every WireCommand, and what it sends (or leaves
// unsent) must agree with the WireCapabilities it declares. Decode fixtures show each wire producing the ServerEvents
// it is responsible for. Adding a provider means adding one entry to `WireUnderTest.all`.

/// A wire and a scripted session of its server messages.
struct WireUnderTest: Sendable, CustomTestStringConvertible {
    enum Step: Sendable {
        /// A command the session sends between server messages (stateful wires need the turn it opens).
        case send(WireCommand)
        case receive(String)
    }

    let provider: Provider
    let make: @Sendable () -> any Wire
    /// One session's server messages, in order. Together they must decode to every event the wire is responsible for.
    let script: [Step]
    /// Messages from a turn the script's last onset superseded; a wire with `turnEpochs` must drop them.
    var stale: [String] = []

    var testDescription: String { provider.rawValue }

    static let all: [WireUnderTest] = [
        WireUnderTest(provider: .openai, make: { OpenAIRealtimeWire(provider: .openai) }, script: openAIScript),
        WireUnderTest(provider: .grok, make: { OpenAIRealtimeWire(provider: .grok) }, script: openAIScript),
        WireUnderTest(provider: .gemini, make: { GeminiLiveWire() }, script: [
            .receive(#"{"setupComplete":{}}"#),
            .receive(#"{"serverContent":{"inputTranscription":{"text":"run the tests"}}}"#),
            .receive(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"QUJD","mimeType":"audio/pcm;rate=24000"}}]}}}"#),
            .receive(#"{"serverContent":{"outputTranscription":{"text":"On it."}}}"#),
            .receive(#"{"serverContent":{"turnComplete":true}}"#),
            .receive(#"{"toolCall":{"functionCalls":[{"id":"c1","name":"list_agents","args":{}}]}}"#),
            .receive(#"{"sessionResumptionUpdate":{"newHandle":"h-1","resumable":true}}"#),
            .receive(#"{"goAway":{"timeLeft":"10s"}}"#),
            .receive(#"{"error":{"message":"boom"}}"#),
        ]),
        WireUnderTest(provider: .local, make: { LocalWire() }, script: [
            .receive(#"{"type":"session.updated"}"#),
            .send(.inputStarted(utteranceID: "u1")),
            .receive(#"{"type":"input.transcription.completed","epoch":1,"utterance_id":"u1","source":"microphone","transcript":"run the tests"}"#),
            .receive(#"{"type":"response.created","epoch":1}"#),
            .receive(#"{"type":"response.audio.delta","epoch":1,"item_id":"i1","delta":"QUJD"}"#),
            .receive(#"{"type":"response.audio_transcript.done","epoch":1,"item_id":"i1","transcript":"On it."}"#),
            .receive(#"{"type":"response.function_call_arguments.done","epoch":1,"call_id":"c1","name":"list_agents","arguments":"{}"}"#),
            .receive(#"{"type":"response.done","epoch":1}"#),
            .receive(#"{"type":"error","error":{"message":"boom"}}"#),
            .send(.inputStarted(utteranceID: "u2")),
        ], stale: [
            #"{"type":"response.audio.delta","epoch":1,"item_id":"i1","delta":"QUJD"}"#,
            #"{"type":"response.function_call_arguments.done","epoch":1,"call_id":"c2","name":"focus","arguments":"{}"}"#,
            #"{"type":"response.done","epoch":1}"#,
        ]),
    ]

    /// OpenAI and xAI speak the same protocol.
    private static let openAIScript: [Step] = [
        .receive(#"{"type":"session.created","session":{}}"#),
        .receive(#"{"type":"input_audio_buffer.speech_started"}"#),
        .receive(#"{"type":"input_audio_buffer.speech_stopped"}"#),
        .receive(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"run the tests"}"#),
        .receive(#"{"type":"response.created"}"#),
        .receive(#"{"type":"response.output_audio.delta","item_id":"i1","delta":"QUJD"}"#),
        .receive(#"{"type":"response.output_audio_transcript.done","transcript":"On it."}"#),
        .receive(#"{"type":"response.function_call_arguments.done","call_id":"c1","name":"list_agents","arguments":"{}"}"#),
        .receive(#"{"type":"response.done"}"#),
        .receive(#"{"type":"error","error":{"message":"boom"}}"#),
    ]

    /// Runs the script on a fresh wire and returns every event it decoded.
    func decodeScript() -> (wire: any Wire, events: [ServerEvent]) {
        let wire = make()
        var events: [ServerEvent] = []
        for step in script {
            switch step {
            case .send(let command): _ = wire.encode(command)
            case .receive(let text): events += wire.decode(text)
            }
        }
        return (wire, events)
    }
}

// MARK: - Encoding: every command, every wire

private let instructions = "Conformance instructions."
private let newInstructions = "Replacement instructions."
private let voice = "conformance-voice"
private let audio = "QUJDRA=="
private let userWords = "conformance user words"
private let resumeHandle = "resume-handle-7"
private let narrowed = ToolList(Array(HerdrTools.schemas.prefix(2)))
private let output = ToolOutput(callID: "call-7", name: "list_agents", output: "tool says ok", epoch: 1)

/// What a wire must do with a command, given what it declares.
enum Expect: Sendable {
    case messages, nothing, either

    static func iff(_ supported: Bool) -> Expect { supported ? .messages : .nothing }
}

struct Scenario: Sendable, CustomTestStringConvertible {
    let name: String
    /// Sent first on the same wire, so the command meets the state it needs (an open utterance, say).
    var prime: [WireCommand] = []
    let command: WireCommand
    let expect: @Sendable (WireCapabilities) -> Expect
    /// More checks on what was sent, when anything was.
    var check: @Sendable (_ wire: any Wire, _ caps: WireCapabilities, _ sent: [[String: Any]]) -> Void = { _, _, _ in }

    var testDescription: String { name }

    static let all: [Scenario] = [
        Scenario(name: "setup with every tool",
                 command: .setup(instructions: instructions, voice: voice, resumeHandle: nil),
                 expect: { _ in .messages },
                 check: { _, _, sent in
                     #expect(sent.count == 1)
                     #expect(json(sent).contains(instructions) && json(sent).contains(voice))
                     #expect(toolNames(sent) == Set(ToolList(HerdrTools.schemas).names))
                 }),
        Scenario(name: "setup with a tool list",
                 command: .setup(instructions: instructions, voice: voice, resumeHandle: nil, tools: narrowed),
                 expect: { _ in .messages },
                 check: { _, _, sent in
                     #expect(sent.count == 1)
                     #expect(toolNames(sent) == Set(narrowed.names))
                 }),
        Scenario(name: "setup resuming a session",
                 command: .setup(instructions: instructions, voice: voice, resumeHandle: resumeHandle),
                 expect: { _ in .messages },
                 check: { _, caps, sent in #expect(json(sent).contains(resumeHandle) == caps.nativeResumption) }),
        Scenario(name: "inputStarted",
                 command: .inputStarted(utteranceID: "utterance-3"),
                 expect: { .iff($0.explicitSpeechOnsets) },
                 check: { _, _, sent in #expect(json(sent).contains("utterance-3")) }),
        Scenario(name: "appendAudio outside an utterance",
                 command: .appendAudio(audio),
                 expect: { .iff(!$0.explicitSpeechOnsets) }),
        Scenario(name: "appendAudio inside an utterance",
                 prime: [.inputStarted(utteranceID: "utterance-3")],
                 command: .appendAudio(audio),
                 expect: { _ in .messages },
                 check: { _, _, sent in #expect(json(sent).contains(audio)) }),
        // Without explicit onsets, server VAD may end the turn from the trailing silence, so a pause may go unsent.
        Scenario(name: "audioPaused ending an utterance",
                 prime: [.inputStarted(utteranceID: "utterance-3"), .appendAudio(audio)],
                 command: .audioPaused,
                 expect: { $0.explicitSpeechOnsets ? .messages : .either }),
        Scenario(name: "clearInput", command: .clearInput, expect: { .iff($0.clearsInput) }),
        Scenario(name: "userText without a reply",
                 command: .userText(userWords, expectsReply: false),
                 expect: { _ in .messages },
                 check: { _, _, sent in #expect(json(sent).contains(userWords)) }),
        Scenario(name: "userText with a reply",
                 command: .userText(userWords, expectsReply: true),
                 expect: { _ in .messages },
                 check: { wire, caps, sent in
                     #expect(json(sent).contains(userWords))
                     // Without explicit replies, the text itself is what asks for the answer.
                     if !caps.explicitReplies {
                         #expect(json(sent) != json(wire.encode(.userText(userWords, expectsReply: false))))
                     }
                 }),
        Scenario(name: "toolOutputs",
                 command: .toolOutputs([output]),
                 expect: { _ in .messages },
                 check: { _, _, sent in #expect(json(sent).contains(output.callID) && json(sent).contains(output.output)) }),
        Scenario(name: "toolOutputs without an epoch",
                 command: .toolOutputs([ToolOutput(callID: output.callID, name: output.name, output: output.output)]),
                 expect: { .iff(!$0.turnEpochs) }),
        Scenario(name: "requestReply", command: .requestReply, expect: { .iff($0.explicitReplies) }),
        Scenario(name: "cancelReply", command: .cancelReply, expect: { .iff($0.explicitReplies) }),
        Scenario(name: "truncate",
                 command: .truncate(itemID: "item-9", audioEndMs: 1200),
                 expect: { .iff($0.explicitReplies) },
                 check: { _, _, sent in #expect(json(sent).contains("item-9")) }),
        Scenario(name: "updateTools",
                 command: .updateTools(narrowed),
                 expect: { .iff($0.dynamicTools) },
                 check: { _, _, sent in #expect(toolNames(sent) == Set(narrowed.names)) }),
        Scenario(name: "updateInstructions",
                 command: .updateInstructions(newInstructions),
                 expect: { .iff($0.dynamicTools) },
                 check: { _, _, sent in #expect(json(sent).contains(newInstructions)) }),
        Scenario(name: "deferReplies on",
                 command: .deferReplies(true),
                 expect: { .iff($0.deferredReplies) },
                 check: { wire, _, sent in
                     #expect(sent.count == 1 && json(sent).contains("turn_detection"))
                     #expect(json(sent) != json(wire.encode(.deferReplies(false))))
                 }),
        Scenario(name: "deferReplies off", command: .deferReplies(false), expect: { .iff($0.deferredReplies) }),
    ]

    /// Exhaustive on purpose: a new WireCommand case doesn't compile until it is named here, and the coverage test
    /// then wants a scenario for it.
    static func caseName(_ command: WireCommand) -> String {
        switch command {
        case .setup: "setup"
        case .updateTools: "updateTools"
        case .updateInstructions: "updateInstructions"
        case .inputStarted: "inputStarted"
        case .appendAudio: "appendAudio"
        case .clearInput: "clearInput"
        case .audioPaused: "audioPaused"
        case .userText: "userText"
        case .toolOutputs: "toolOutputs"
        case .requestReply: "requestReply"
        case .cancelReply: "cancelReply"
        case .truncate: "truncate"
        case .deferReplies: "deferReplies"
        }
    }

    static let caseNames: Set<String> = [
        "setup", "updateTools", "updateInstructions", "inputStarted", "appendAudio", "clearInput", "audioPaused",
        "userText", "toolOutputs", "requestReply", "cancelReply", "truncate", "deferReplies",
    ]
}

private func json(_ messages: [[String: Any]]) -> String {
    let data = try? JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys, .withoutEscapingSlashes])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
}

/// The function names a message offers, in either shape: `tools[].name` (OpenAI, xAI, Local) or
/// `tools[].functionDeclarations[].name` (Gemini). Built-in tools without a name (web search) are left out.
private func toolNames(_ value: Any) -> Set<String> {
    var names = Set<String>()
    func walk(_ value: Any) {
        if let array = value as? [Any] { return array.forEach(walk) }
        guard let object = value as? [String: Any] else { return }
        for (key, child) in object {
            guard key == "tools", let tools = child as? [[String: Any]] else {
                walk(child)
                continue
            }
            for tool in tools {
                if let name = tool["name"] as? String { names.insert(name) }
                for declaration in tool["functionDeclarations"] as? [[String: Any]] ?? [] {
                    if let name = declaration["name"] as? String { names.insert(name) }
                }
            }
        }
    }
    walk(value)
    return names
}

@Suite("Wire conformance") struct WireConformanceTests {
    @Test("the wires under test are exactly the providers, built as each provider builds its wire")
    func everyProviderIsUnderTest() {
        let providers = WireUnderTest.all.map(\.provider)
        #expect(providers.count == Set(providers).count)
        #expect(Set(providers) == Set(Provider.allCases))
        let setup = WireCommand.setup(instructions: instructions, voice: voice, resumeHandle: resumeHandle)
        for entry in WireUnderTest.all {
            let built = entry.provider.makeWire(environment: [:])
            #expect(type(of: entry.make()) == type(of: built), "\(entry.provider)")
            #expect(entry.make().capabilities == entry.provider.capabilities, "\(entry.provider)")
            #expect(json(entry.make().encode(setup)) == json(built.encode(setup)), "\(entry.provider)")
        }
    }

    @Test("every WireCommand case has a scenario")
    func everyCommandIsCovered() {
        #expect(Set(Scenario.all.map { Scenario.caseName($0.command) }) == Scenario.caseNames)
    }

    @Test("a command's messages are JSON objects in the wire's shape, sent exactly when its capabilities say",
          arguments: WireUnderTest.all, Scenario.all)
    func command(_ entry: WireUnderTest, _ scenario: Scenario) {
        let wire = entry.make()
        let caps = wire.capabilities
        for command in scenario.prime { _ = wire.encode(command) }
        let sent = wire.encode(scenario.command)

        switch scenario.expect(caps) {
        case .messages: #expect(!sent.isEmpty, "\(entry.provider) sent nothing for \(scenario.name)")
        case .nothing: #expect(sent.isEmpty, "\(entry.provider) sent \(json(sent)) for \(scenario.name), which it declares unsupported")
        case .either: break
        }
        for message in sent {
            #expect(JSONSerialization.isValidJSONObject(message), "\(message)")
            // Typed messages (OpenAI, xAI, Local) or a one-key envelope (Gemini's setup, realtimeInput, ...).
            let typed = (message["type"] as? String).map { !$0.isEmpty } ?? false
            let envelope = message.count == 1 && message.values.first is [String: Any]
            #expect(typed || envelope, "\(entry.provider): \(json([message])) has neither a type nor a one-key envelope")
            if caps.turnEpochs, Scenario.caseName(scenario.command) != "setup" {
                #expect(message["epoch"] is Int, "\(entry.provider): \(json([message])) carries no epoch")
            }
        }
        if !sent.isEmpty { scenario.check(wire, caps, sent) }
    }

    // MARK: decoding

    enum Duty: String, CaseIterable {
        case sessionReady, speechStarted, userTranscript, responseCreated, audioDelta, assistantTranscript
        case functionCall, responseDone, resumptionHandle, error

        init?(_ event: ServerEvent) {
            switch event {
            case .sessionReady: self = .sessionReady
            case .speechStarted: self = .speechStarted
            case .userTranscript: self = .userTranscript
            case .responseCreated: self = .responseCreated
            case .audioDelta: self = .audioDelta
            case .assistantTranscript, .assistantTranscriptItem: self = .assistantTranscript
            case .functionCall, .localFunctionCall: self = .functionCall
            case .responseDone: self = .responseDone
            case .resumptionHandle: self = .resumptionHandle
            case .error: self = .error
            default: return nil
            }
        }

        /// What a wire declaring `caps` must decode from its own provider's messages.
        static func owed(by caps: WireCapabilities) -> Set<Duty> {
            var duties: Set<Duty> = [.userTranscript, .responseCreated, .audioDelta, .assistantTranscript,
                                     .functionCall, .responseDone, .error]
            if caps.setupHandshake { duties.insert(.sessionReady) }
            if !caps.explicitSpeechOnsets { duties.insert(.speechStarted) } // otherwise the session reports it
            if caps.nativeResumption { duties.insert(.resumptionHandle) }
            return duties
        }
    }

    @Test("each wire decodes the core events it is responsible for", arguments: WireUnderTest.all)
    func decodesItsDuties(_ entry: WireUnderTest) {
        let (wire, events) = entry.decodeScript()
        let caps = wire.capabilities
        let owed = Duty.owed(by: caps)
        let done = Set(events.compactMap(Duty.init(_:)))
        #expect(owed.subtracting(done).isEmpty, "\(entry.provider) never decoded \(owed.subtracting(done).map(\.rawValue).sorted())")
        // The capability-bound events appear only where declared.
        #expect(done.contains(.sessionReady) == caps.setupHandshake)
        #expect(done.contains(.speechStarted) == !caps.explicitSpeechOnsets)
        #expect(done.contains(.resumptionHandle) == caps.nativeResumption)

        let calls = events.compactMap { event -> (callID: String, name: String, epoch: Int?)? in
            switch event {
            case let .functionCall(callID, name, _): (callID, name, nil)
            case let .localFunctionCall(epoch, callID, name, _): (callID, name, epoch)
            default: nil
            }
        }
        #expect(calls.map(\.callID) == ["c1"] && calls.map(\.name) == ["list_agents"])
        // With epochs a call is bound to the turn it belongs to; without, it carries none.
        #expect(calls.allSatisfy { ($0.epoch != nil) == caps.turnEpochs })
        if caps.turnEpochs, let epoch = calls.first?.epoch { #expect(!wire.isCurrent(epoch: epoch)) } // the script moved on
    }

    @Test("a wire with epochs drops a superseded turn's events", arguments: WireUnderTest.all)
    func dropsStaleTurns(_ entry: WireUnderTest) {
        let (wire, _) = entry.decodeScript()
        guard wire.capabilities.turnEpochs else {
            #expect(entry.stale.isEmpty, "\(entry.provider) has stale fixtures but no epochs to drop them by")
            return
        }
        #expect(!entry.stale.isEmpty, "\(entry.provider) declares turnEpochs but has no stale fixtures")
        for text in entry.stale { #expect(wire.decode(text).isEmpty, "\(text)") }
    }

    @Test("an undecodable message is one error on every wire", arguments: WireUnderTest.all)
    func undecodableIsAnError(_ entry: WireUnderTest) {
        let events = entry.make().decode("not json")
        #expect(events.count == 1 && events.first.flatMap(Duty.init(_:)) == .error)
    }
}
