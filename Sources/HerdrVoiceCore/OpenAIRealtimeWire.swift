import Foundation

/// The OpenAI Realtime protocol, which xAI's Grok Voice also speaks. These are the exact messages herdr-voice
/// sent before the wire layer existed (see WireGoldenTests).
public final class OpenAIRealtimeWire: Wire, Sendable {
    private let provider: Provider

    public init(provider: Provider) {
        self.provider = provider
    }

    /// OpenAI can hold a turn's reply and keep its speech detection (`create_response: false`). xAI documents no
    /// such switch, only turning detection off, which leaves the session to guess where turns end from the mic: its
    /// server VAD ends and answers every turn, as Gemini's does.
    public var capabilities: WireCapabilities {
        WireCapabilities(explicitReplies: true, nativeResumption: false, dynamicTools: true,
                         deferredReplies: provider == .openai)
    }

    public func encode(_ command: WireCommand) -> [[String: Any]] {
        switch command {
        case let .setup(instructions, voice, _, tools):
            return [provider.sessionUpdate(instructions: instructions, voice: voice,
                                           tools: tools?.definitions ?? HerdrTools.schemas)]
        case .updateTools(let tools):
            return [provider.toolsUpdate(tools.definitions)]
        case .updateInstructions(let instructions):
            return [provider.instructionsUpdate(instructions)]
        case .inputStarted:
            return []
        case .appendAudio(let b64):
            return [["type": "input_audio_buffer.append", "audio": b64]]
        case .clearInput:
            return [["type": "input_audio_buffer.clear"]]
        case .audioPaused:
            return [] // server VAD ends the turn from the trailing silence the gate already sent
        case let .userText(text, _):
            return [["type": "conversation.item.create", "item": [
                "type": "message", "role": "user", "content": [["type": "input_text", "text": text]],
            ]]]
        case .toolOutputs(let outputs):
            return outputs.map {
                ["type": "conversation.item.create", "item": [
                    "type": "function_call_output", "call_id": $0.callID, "output": $0.output,
                ]]
            }
        case .requestReply:
            return [["type": "response.create"]]
        case .cancelReply:
            return [["type": "response.cancel"]]
        case let .truncate(itemID, audioEndMs):
            return [["type": "conversation.item.truncate", "item_id": itemID, "content_index": 0, "audio_end_ms": audioEndMs]]
        case .deferReplies(let on):
            return capabilities.deferredReplies ? [provider.turnDetectionUpdate(deferReplies: on)] : []
        }
    }

    public func decode(_ text: String) -> [ServerEvent] {
        [ServerEvent.decode(text)]
    }
}
