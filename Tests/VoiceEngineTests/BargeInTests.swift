import Foundation
import HerdrVoiceCore
import Testing
@testable import VoiceEngine

/// Noise is not you. A burst of it (a door, a cough, a click), loud enough to open the speech gate and for the
/// provider's VAD to take for speech, must not cut her off, cancel the cooldown or start a turn; speech does. Each
/// test drives the real mic path into a fake socket while she replies, and plays the provider's speech events back.
/// The companion's turn-taking hears what `onSpeech` reports, as in the app.
@Suite(.serialized) @MainActor struct BargeInTests {
    // MARK: noise while she replies

    @Test(arguments: [Provider.grok, Provider.openai])
    func noiseWhileSheRepliesDoesNotInterrupt(provider: Provider) async {
        let (rig, heard) = await conversation(provider)
        await rig.serverSays(#"{"type":"response.created"}"#) // her reply is on its way
        let mark = rig.mark
        await noiseBurst(rig)
        #expect(!rig.types(since: mark).contains("response.cancel"), "noise cancelled her reply")
        #expect(!rig.types(since: mark).contains("conversation.item.truncate"), "noise cut her off")
        #expect(heard.events.isEmpty, "noise counted as you speaking: \(heard.events)")
    }

    @Test(arguments: [Provider.grok, Provider.openai])
    func speechWhileSheRepliesInterrupts(provider: Provider) async {
        let (rig, heard) = await conversation(provider)
        await rig.serverSays(#"{"type":"response.created"}"#)
        rig.loud(25, "speech")
        await rig.serverSays(#"{"type":"input_audio_buffer.speech_started"}"#)
        #expect(heard.events == [true], "talking over her is you speaking")
        rig.quiet(60, "speech")
        await rig.serverSays(#"{"type":"input_audio_buffer.speech_stopped"}"#)
        #expect(heard.events == [true, false])
    }

    // MARK: Grok's turns

    /// Grok's server VAD ends and answers every turn, as in 0.2: tap-to-talk doesn't turn it off.
    @Test func grokKeepsItsServerVADInTapToTalk() async {
        let (rig, _) = await conversation(.grok)
        let updates = rig.frames.filter { $0["type"] as? String == "session.update" }
        let detections = updates.compactMap { ($0["session"] as? [String: Any])?.keys.contains("turn_detection") == true
            ? ($0["session"] as? [String: Any])?["turn_detection"] : nil }
        #expect(detections.count == 1, "only the setup sets turn detection: \(detections)")
        #expect((detections.first as? [String: Any])?["type"] as? String == "server_vad")
        #expect(!rig.types(since: 0).contains("input_audio_buffer.commit"), "the provider commits each turn")
    }

    // MARK: OpenAI's cooldown

    /// After you stop, the cooldown waits half a second for more before asking for the reply. Noise in it is not more.
    @Test func noiseDoesNotCancelTheCooldown() async {
        let (rig, heard) = await conversation(.openai)
        var turns = TurnTaking()
        let t0 = Date()
        var clock: TimeInterval = 1 // each speech event 100 ms after the last
        _ = turns.handle(.tap, at: t0)
        heard.onEvent = {
            clock += 0.1
            _ = turns.handle($0 ? .speechStarted : .speechStopped, at: t0.addingTimeInterval(clock))
        }

        rig.loud(25, "speech")
        await rig.serverSays(#"{"type":"input_audio_buffer.speech_started"}"#)
        rig.quiet(60, "speech")
        await rig.serverSays(#"{"type":"input_audio_buffer.speech_stopped"}"#)
        let cooldown = TurnTaking.Phase.cooldown(since: t0.addingTimeInterval(1.2), until: t0.addingTimeInterval(1.7))
        #expect(turns.phase == cooldown)

        await noiseBurst(rig)
        #expect(turns.phase == cooldown, "noise cancelled the cooldown")
        #expect(turns.handle(.tick, at: t0.addingTimeInterval(1.7)) == [.submit], "the turn goes when it runs out")
    }

    /// The follow-up window lets you talk without the key; noise in it is not a turn of yours.
    @Test func noiseDoesNotStartATurnInTheFollowUp() async {
        let (rig, heard) = await conversation(.openai)
        var turns = TurnTaking()
        let t0 = Date()
        for (event, at) in [(TurnTaking.Event.tap, 0.0), (.speechStarted, 0.5), (.speechStopped, 2), (.tick, 2.5),
                            (.assistant(busy: true), 3), (.assistant(busy: false), 6)] {
            _ = turns.handle(event, at: t0.addingTimeInterval(at))
        }
        guard case .followUp = turns.phase else {
            Issue.record("not in the follow-up: \(turns.phase)")
            return
        }
        let window = turns.phase
        heard.onEvent = { _ = turns.handle($0 ? .speechStarted : .speechStopped, at: t0.addingTimeInterval(7)) }
        await noiseBurst(rig)
        #expect(turns.phase == window, "noise started a turn: \(turns.phase)")
    }

    // MARK: helpers

    /// What the session reported through `onSpeech`, in order.
    final class Heard {
        var events: [Bool] = []
        var onEvent: ((Bool) -> Void)?
    }

    /// Tap-to-talk, as the companion runs it: a tap opened the session, which is up and listening.
    private func conversation(_ provider: Provider) async -> (SessionRig, Heard) {
        let rig = SessionRig(provider)
        let heard = Heard()
        rig.session.onSpeech = { started in
            heard.events.append(started)
            heard.onEvent?(started)
        }
        rig.session.deferReplies = true
        rig.session.setStandby(true)
        rig.session.listen()
        await rig.serverUp()
        return (rig, heard)
    }

    /// 100 ms of something loud that isn't speech (enough to open the speech gate), the quiet after it, and the
    /// provider's VAD taking it for speech and then for over.
    private func noiseBurst(_ rig: SessionRig) async {
        rig.loud(5, "noise")
        rig.quiet(10, "noise")
        await rig.settle()
        await rig.serverSays(#"{"type":"input_audio_buffer.speech_started"}"#)
        rig.quiet(50, "noise")
        await rig.serverSays(#"{"type":"input_audio_buffer.speech_stopped"}"#)
    }
}
