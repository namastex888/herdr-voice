import Foundation
import HerdrVoiceCore
import Testing
@testable import VoiceEngine

/// Mute is absolute: from the press until the user unmutes, no mic audio, utterance start or commit leaves the Mac,
/// whatever the session is doing (live, closed, connecting, the key down, listening, the cooldown, the follow-up,
/// paused) and whatever reopens it. Each test drives the real mic path (`Audio.onMic` → `Realtime`) into a fake
/// socket and reads every frame sent after the press.
@Suite(.serialized) @MainActor struct MuteTests {
    // MARK: always on

    @Test func liveSessionStreamsUntilMutedThenNothingLeaves() async {
        let rig = SessionRig(.grok)
        rig.session.connect()
        await rig.serverUp()
        await rig.say("before")
        #expect(rig.micFrames(since: 0).contains { $0.description.contains("before#") }, "the rig hears speech at all")

        let press = rig.mark
        rig.session.setMuted(true)
        await rig.say("muted")
        expectNothingLeft(rig, since: press)
        #expect(rig.types(since: press).contains("input_audio_buffer.clear"), "what the provider buffered is dropped")
    }

    @Test func mutedSpeechNeverOpensAClosedSession() async {
        let rig = SessionRig(.grok)
        rig.session.setMuted(true)
        await rig.say("muted")
        #expect(rig.opened == 0)

        rig.session.setMuted(false) // the explicit unmute: from here speech reopens it
        await rig.say("after")
        #expect(rig.opened == 1)
        await rig.serverUp()
        #expect(rig.micFrames(since: 0).allSatisfy { !$0.description.contains("muted#") })
        #expect(rig.micFrames(since: 0).contains { $0.description.contains("after#") })
    }

    @Test func pauseSendsNothingAndResumeStreamsAgain() async {
        let rig = SessionRig(.grok)
        rig.session.connect()
        await rig.serverUp()
        let press = rig.mark
        rig.session.pause()
        await rig.say("paused")
        expectNothingLeft(rig, since: press)

        rig.session.resume()
        await rig.say("after")
        let after = rig.micFrames(since: press)
        #expect(after.allSatisfy { !$0.description.contains("paused#") })
        #expect(after.contains { $0.description.contains("after#") })
    }

    /// What was said while muted is gone for good: unmuting sends only what is said after it.
    @Test func speechWhileMutedIsNotSentAfterUnmute() async {
        let rig = SessionRig(.grok)
        rig.session.connect()
        await rig.serverUp()
        let press = rig.mark
        rig.session.setMuted(true)
        rig.loud(10, "muted") // mid-sentence when the unmute lands
        rig.session.setMuted(false)
        rig.quiet(60, "after")
        await rig.say("after")
        let sent = rig.micFrames(since: press)
        #expect(sent.allSatisfy { !$0.description.contains("muted#") }, "\(sent)")
        #expect(sent.contains { $0.description.contains("after#") })
    }

    // MARK: tap to talk

    /// Listening, the cooldown and the follow-up window all have the session up and the mic on: muting in any of
    /// them sends nothing, and the turn the cooldown submits commits nothing.
    @Test func mutedConversationSendsAndCommitsNothing() async {
        let rig = tapToTalk(.grok)
        rig.session.listen()
        await rig.serverUp()
        await rig.say("turn") // listening → speech stops → cooldown
        rig.session.submitTurn()
        #expect(rig.types(since: 0).contains("input_audio_buffer.commit"), "an unmuted turn is committed")
        await rig.serverSays(#"{"type":"response.created"}"#)
        await rig.serverSays(#"{"type":"response.done"}"#) // her reply is over: the follow-up window

        let press = rig.mark
        rig.session.setMuted(true)
        await rig.say("muted")
        rig.session.submitTurn() // the cooldown runs out
        expectNothingLeft(rig, since: press)
        #expect(!rig.types(since: press).contains("response.create"))
    }

    /// A tap, a conversation's end and the next tap while muted: nothing unmutes, nothing leaves.
    @Test func activationNeverUnmutes() async {
        let rig = tapToTalk(.grok)
        rig.session.setMuted(true)
        rig.session.buffer()
        rig.session.listen()
        await rig.serverUp()
        await rig.say("muted")
        rig.session.rest("conversation over")
        rig.session.buffer()
        await rig.say("muted")
        rig.session.listen()
        await rig.serverUp()
        await rig.say("muted")
        #expect(rig.session.muted && !rig.session.micOpen)
        expectNothingLeft(rig, since: 0)
    }

    // MARK: helpers

    /// Nothing from the mic left after `press`; what did is listed (its kinds and first labels) when it fails.
    private func expectNothingLeft(_ rig: SessionRig, since press: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        let leaked = rig.micFrames(since: press)
        let audio = leaked.filter { if case .audio = $0 { true } else { false } }
        let summary = "\(audio.count) audio chunk(s) \(audio.prefix(2).map(\.description)), "
            + "markers \(leaked.filter { if case .audio = $0 { false } else { true } }.map(\.description))"
        #expect(leaked.isEmpty, "left while muted: \(summary)", sourceLocation: sourceLocation)
    }

    private func tapToTalk(_ provider: Provider) -> SessionRig {
        let rig = SessionRig(provider)
        rig.session.deferReplies = true
        rig.session.setStandby(true)
        return rig
    }
}
