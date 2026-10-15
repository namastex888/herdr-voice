import CryptoKit
import Foundation
import Testing
@testable import HerdrVoiceCore

// Golden tests: recorded from the shipping build (main b72be42) BEFORE the wire-protocol refactor that added
// Gemini Live. The OpenAI and xAI paths must keep producing exactly these bytes and decoding exactly these events.

private func sha(_ obj: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Test("setup message is byte-identical to the shipping build", arguments: [
    (Provider.openai, "a022f5c3f4db68f3d8f585e911120d1bc1a1bd4e34be3c366f8612fb4f2c5e91"), // transcription: gpt-transcribe
    (Provider.grok, "10ad0d4bfe0c876c370dd7ff6366a43dec38a917134bfa276ee3f596a0a3ce5b"),
])
func setupGolden(provider: Provider, expected: String) {
    #expect(sha(withoutLaterTools(provider.sessionUpdate(instructions: "INSTR", voice: "VOICE"))) == expected)
}

/// Tools added after the recording (workspace/tab/worktree management, panes, start_agent) are left out; everything else must match.
private func withoutLaterTools(_ update: [String: Any]) -> [String: Any] {
    guard var session = update["session"] as? [String: Any], let tools = session["tools"] as? [[String: Any]] else { return update }
    session["tools"] = tools.filter { !HerdrTools.manageTools.union(HerdrTools.paneTools).union(["start_agent", "split_pane"]).union(HerdrTools.paneControlTools).contains($0["name"] as? String ?? "") }
    var out = update
    out["session"] = session
    return out
}

@Test("every OpenAI/xAI server event decodes as it did", arguments: [
    (#"{"type":"response.output_audio.delta","item_id":"i1","delta":"QUJD"}"#, ServerEvent.audioDelta(itemID: "i1", base64: "QUJD")),
    (#"{"type":"response.audio.delta","item_id":"i1","delta":"QUJD"}"#, .audioDelta(itemID: "i1", base64: "QUJD")),
    (#"{"type":"response.output_audio_transcript.delta","delta":"He"}"#, .assistantTranscriptDelta("He")),
    (#"{"type":"response.output_audio_transcript.done","transcript":"Hello."}"#, .assistantTranscript("Hello.")),
    (#"{"type":"response.audio_transcript.done","transcript":"Hello."}"#, .assistantTranscript("Hello.")),
    (#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"yes"}"#, .userTranscript("yes")),
    (#"{"type":"input_audio_buffer.speech_started"}"#, .speechStarted),
    (#"{"type":"input_audio_buffer.speech_stopped"}"#, .speechStopped),
    (#"{"type":"response.function_call_arguments.done","call_id":"c1","name":"focus","arguments":"{\"target\":\"x\"}"}"#,
     .functionCall(callID: "c1", name: "focus", arguments: #"{"target":"x"}"#)),
    (#"{"type":"response.created"}"#, .responseCreated),
    (#"{"type":"response.done"}"#, .responseDone),
    (#"{"type":"error","error":{"message":"boom"}}"#, .error("boom")),
    (#"{"type":"session.updated"}"#, .ignored("session.updated")),
])
func decodeGolden(json: String, expected: ServerEvent) {
    #expect(ServerEvent.decode(json) == expected)
}

// The exact messages the pre-refactor Realtime.swift built inline (main b72be42), one per command.
private func json(_ obj: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
}

@Test("OpenAI/xAI commands encode exactly as the shipping build sent them", arguments: [Provider.openai, Provider.grok])
func commandGoldens(provider: Provider) {
    let wire = OpenAIRealtimeWire(provider: provider)
    let cases: [(WireCommand, [[String: Any]])] = [
        (.appendAudio("QUJD"), [["type": "input_audio_buffer.append", "audio": "QUJD"]]),
        (.clearInput, [["type": "input_audio_buffer.clear"]]),
        (.audioPaused, []),
        (.userText("[herdr] done", expectsReply: true), [["type": "conversation.item.create", "item": [
            "type": "message", "role": "user", "content": [["type": "input_text", "text": "[herdr] done"]]]]]),
        (.userText("[context] recap", expectsReply: false), [["type": "conversation.item.create", "item": [
            "type": "message", "role": "user", "content": [["type": "input_text", "text": "[context] recap"]]]]]),
        (.toolOutputs([ToolOutput(callID: "c1", name: "focus", output: "focused")]), [["type": "conversation.item.create",
            "item": ["type": "function_call_output", "call_id": "c1", "output": "focused"]]]),
        (.requestReply, [["type": "response.create"]]),
        (.cancelReply, [["type": "response.cancel"]]),
        (.truncate(itemID: "i9", audioEndMs: 1234), [["type": "conversation.item.truncate", "item_id": "i9",
                                                      "content_index": 0, "audio_end_ms": 1234]]),
        (.setup(instructions: "INSTR", voice: "VOICE", resumeHandle: "ignored"),
         [provider.sessionUpdate(instructions: "INSTR", voice: "VOICE")]),
    ]
    for (command, expected) in cases {
        #expect(wire.encode(command).map(json) == expected.map(json), "\(command)")
    }
    // Deferred replies, which only a session opting in uses, are the one difference between them: xAI can't hold a
    // reply without turning its speech detection off, so it answers every turn by itself, as in 0.2.
    #expect(wire.capabilities == WireCapabilities(explicitReplies: true, nativeResumption: false, dynamicTools: true,
                                                  deferredReplies: provider == .openai))
}

@Test("deferring replies: OpenAI keeps its VAD without answering; xAI keeps answering by itself")
func deferredReplies() {
    let openai = OpenAIRealtimeWire(provider: .openai), grok = OpenAIRealtimeWire(provider: .grok)
    let held: [String: Any] = ["type": "session.update", "session": ["type": "realtime", "audio": ["input": [
        "turn_detection": ["type": "semantic_vad", "create_response": false, "interrupt_response": true]]]]]
    let answering: [String: Any] = ["type": "session.update", "session": ["type": "realtime", "audio": ["input": [
        "turn_detection": ["type": "semantic_vad", "create_response": true, "interrupt_response": true]]]]]
    #expect(openai.encode(.deferReplies(true)).map(json) == [json(held)])
    #expect(openai.encode(.deferReplies(false)).map(json) == [json(answering)])
    // Grok's turn detection stays the server VAD its setup turns on (the setup golden above, unchanged since 0.2).
    #expect(grok.encode(.deferReplies(true)).isEmpty && grok.encode(.deferReplies(false)).isEmpty)
    // Setting back to answering by itself is exactly what setup sets up.
    let setup = Provider.openai.sessionUpdate(instructions: "I", voice: "V")
    let setupDetection = ((setup["session"] as? [String: Any])?["audio"] as? [String: Any]).map { json($0) } ?? ""
    #expect(setupDetection.contains(#""create_response":true"#) && setupDetection.contains("semantic_vad"))
}

@Test("tools can be narrowed mid-session where the provider allows it")
func toolUpdates() {
    let one = ToolList([["type": "function", "name": "open_app", "description": "d", "parameters": ["type": "object"]]])
    #expect(OpenAIRealtimeWire(provider: .openai).encode(.updateTools(one)).map(json)
            == [json(["type": "session.update", "session": ["type": "realtime", "tools": one.definitions, "tool_choice": "auto"]])])
    // Grok keeps its own web search alongside whatever tools are routed in.
    #expect(OpenAIRealtimeWire(provider: .grok).encode(.updateTools(one)).map(json)
            == [json(["type": "session.update", "session": ["tools": one.definitions + [["type": "web_search"]]]])])
    // Gemini Live and the local bridge take tools only at setup.
    #expect(GeminiLiveWire().encode(.updateTools(one)).isEmpty && !GeminiLiveWire().capabilities.dynamicTools)
    #expect(LocalWire().encode(.updateTools(one)).isEmpty && !LocalWire().capabilities.dynamicTools)
    // A setup can carry the routed tools instead of every Herdr tool.
    let setup = OpenAIRealtimeWire(provider: .openai).encode(.setup(instructions: "I", voice: "V", resumeHandle: nil, tools: one))
    #expect(((setup.first?["session"] as? [String: Any])?["tools"] as? [[String: Any]])?.count == 1)
}

@Test("instructions can be replaced mid-session where the provider allows it")
func instructionUpdates() {
    #expect(OpenAIRealtimeWire(provider: .openai).encode(.updateInstructions("NEW")).map(json)
            == [json(["type": "session.update", "session": ["type": "realtime", "instructions": "NEW"]])])
    #expect(OpenAIRealtimeWire(provider: .grok).encode(.updateInstructions("NEW")).map(json)
            == [json(["type": "session.update", "session": ["instructions": "NEW"]])])
    // Gemini Live and the local bridge take instructions only at setup; the session renews the connection instead.
    #expect(GeminiLiveWire().encode(.updateInstructions("NEW")).isEmpty)
    #expect(LocalWire().encode(.updateInstructions("NEW")).isEmpty)
}

@Test("OpenAI/xAI connect with the same bearer header as before", arguments: [Provider.openai, Provider.grok])
func requestGolden(provider: Provider) {
    let request = provider.request(key: "k-123")
    #expect(request.url == provider.url)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k-123")
}
