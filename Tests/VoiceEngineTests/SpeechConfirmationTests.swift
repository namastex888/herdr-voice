import Foundation
import HerdrVoiceCore
import Testing
@testable import VoiceEngine

/// How the provider's speech events and the mic's speech sensor (the rig's `TagSensor`) agree on you speaking: while
/// she plays, in either order, and at the end of your turn.
@Suite(.serialized) @MainActor struct SpeechConfirmationTests {
    @Test(arguments: [Provider.grok, Provider.openai])
    func speechCutsHerPlaybackAndNoiseDoesNot(provider: Provider) async {
        let (rig, heard) = await live(provider)
        await herReply(rig)
        #expect(rig.session.audio.isSpeaking)

        let noise = rig.mark
        rig.loud(5, "noise")
        rig.quiet(10, "noise")
        await rig.serverSays(started)
        await rig.serverSays(stopped)
        #expect(rig.session.audio.isSpeaking, "noise cut her off")
        #expect(!rig.types(since: noise).contains("conversation.item.truncate"))
        #expect(heard.events.isEmpty)

        let speech = rig.mark
        rig.loud(25, "speech")
        await rig.serverSays(started)
        #expect(!rig.session.audio.isSpeaking, "talking over her stops her")
        #expect(rig.types(since: speech).contains("conversation.item.truncate"), "the provider learns what was heard")
        #expect(heard.events == [true])
    }

    /// The provider's VAD can hear you before the mic's sensor does: its onset waits for the sensor.
    @Test func theProviderMayHearYouFirst() async {
        let (rig, heard) = await live(.grok)
        await herReply(rig)
        await rig.serverSays(started)
        #expect(rig.session.audio.isSpeaking && heard.events.isEmpty, "nothing confirmed it yet")
        rig.loud(25, "speech")
        await rig.settle()
        #expect(!rig.session.audio.isSpeaking)
        #expect(heard.events == [true])
    }

    /// Speech the sensor hears after the provider's onset has ended doesn't revive it.
    @Test func anOnsetThatEndedIsNotConfirmedLater() async {
        let (rig, heard) = await live(.grok)
        await herReply(rig)
        await rig.serverSays(started)
        await rig.serverSays(stopped)
        rig.loud(25, "speech")
        await rig.settle()
        #expect(rig.session.audio.isSpeaking)
        #expect(heard.events.isEmpty)
    }

    /// A pause the provider takes for the end of your turn isn't, while the mic still hears you: the end waits for it.
    @Test func yourTurnEndsWhenTheMicHearsYouStop() async {
        let (rig, heard) = await live(.openai)
        rig.loud(25, "speech")
        await rig.serverSays(started)
        rig.loud(5, "speech")
        await rig.serverSays(stopped)
        #expect(heard.events == [true], "you are still talking")
        rig.quiet(5, "speech")
        await rig.settle()
        #expect(heard.events == [true, false])
    }

    /// Local OpenLive has no server VAD: its speech gate marks each utterance, and its runtime drops the reply at the
    /// onset, so the onset is taken as you at once (no second opinion to wait for).
    @Test func localTakesItsGateOnsetAsYou() async {
        let rig = SessionRig(.local)
        let heard = Heard()
        rig.session.onSpeech = { heard.events.append($0) }
        rig.session.connect()
        await rig.serverUp()
        rig.loud(5, "noise")
        await rig.settle()
        #expect(heard.events == [true])
    }

    // MARK: helpers

    private let started = #"{"type":"input_audio_buffer.speech_started"}"#
    private let stopped = #"{"type":"input_audio_buffer.speech_stopped"}"#

    final class Heard {
        var events: [Bool] = []
    }

    private func live(_ provider: Provider) async -> (SessionRig, Heard) {
        let rig = SessionRig(provider)
        let heard = Heard()
        rig.session.onSpeech = { heard.events.append($0) }
        rig.session.connect()
        await rig.serverUp()
        return (rig, heard)
    }

    /// Her reply starts playing (a session that was never started keeps it in the playback ledger until cut).
    private func herReply(_ rig: SessionRig) async {
        await rig.serverSays(#"{"type":"response.created"}"#)
        let pcm = Data(count: 960).base64EncodedString() // 20 ms of silence at 24 kHz
        await rig.serverSays(#"{"type":"response.output_audio.delta","item_id":"i1","delta":"\#(pcm)"}"#)
    }
}
