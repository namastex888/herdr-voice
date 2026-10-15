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

    /// Speech reopens a closed session and is held through the handshake; muting meanwhile must drop it, not
    /// replay it the moment the session comes up.
    @Test func speechHeldWhileReconnectingIsDroppedByMute() async {
        let rig = SessionRig(.grok)
        await rig.say("held")
        #expect(rig.opened == 1, "speech reopened the session")
        let press = rig.mark
        rig.session.setMuted(true)
        await rig.serverUp()
        expectNothingLeft(rig, since: press)
    }

    /// The plugin's ⌥⌘M and orb click (`toggleMute`) on a session closed while quiet, its usual state between
    /// sentences: the press has to mute, or the next sentence reopens the session and is answered.
    @Test func toggleOnAClosedSessionMutes() async {
        let rig = SessionRig(.grok)
        rig.session.toggleMute()
        #expect(rig.session.muted)
        await rig.say("muted")
        #expect(rig.opened == 0)
        expectNothingLeft(rig, since: 0)

        rig.session.toggleMute() // pressed again: unmuted, and listening
        #expect(!rig.session.muted)
        await rig.say("after")
        #expect(rig.opened == 1)
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

    /// Right ⌘ goes down: the mic's audio is kept for the tap. Muting before the tap drops it; the tap then opens a
    /// session that hears nothing.
    @Test func keyDownAudioIsDroppedByMuteBeforeTheTap() async {
        let rig = tapToTalk(.grok)
        rig.session.buffer()
        await rig.say("kept")
        #expect(rig.opened == 0, "the key down connects nothing")
        let press = rig.mark
        rig.session.setMuted(true)
        rig.session.listen() // the tap
        await rig.serverUp()
        expectNothingLeft(rig, since: press)
        #expect(rig.session.muted, "a tap doesn't unmute")
    }

    /// The same with a session already up (her report reopened it): the kept audio would go at the tap.
    @Test func keyDownAudioIsDroppedByMuteWhileASessionIsUp() async {
        let rig = tapToTalk(.grok)
        rig.session.listen()
        await rig.serverUp()
        rig.session.buffer()
        await rig.say("kept")
        let press = rig.mark
        rig.session.setMuted(true)
        rig.session.listen()
        await rig.settle()
        expectNothingLeft(rig, since: press)
    }

    /// Listening, the cooldown and the follow-up window all have the session up and the mic on: muting in any of
    /// them sends nothing, and the turn the cooldown submits asks for no reply. (OpenAI: the provider with a cooldown.)
    @Test func mutedConversationSendsAndAsksNothing() async {
        let rig = tapToTalk(.openai)
        rig.session.listen()
        await rig.serverUp()
        await rig.serverSays(#"{"type":"response.created"}"#) // the greeting
        await rig.serverSays(#"{"type":"response.done"}"#)
        await rig.say("turn") // listening → speech stops → cooldown
        let turn = rig.mark
        rig.session.submitTurn()
        #expect(rig.types(since: turn).contains("response.create"), "an unmuted turn is answered")
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

    // MARK: the provider's own buffer

    /// Gemini has no way to drop what it heard: its end-of-stream answers it. Muting mid-sentence must not send it.
    @Test func geminiMuteDoesNotEndTheTurnItWasHearing() async {
        let rig = SessionRig(.gemini)
        rig.session.connect()
        await rig.serverUp()
        rig.loud(20, "sentence") // mid-sentence
        await rig.settle()
        #expect(!rig.micFrames(since: 0).isEmpty)
        let press = rig.mark
        rig.session.setMuted(true)
        await rig.say("muted")
        expectNothingLeft(rig, since: press)
    }

    /// Local marks each utterance itself; one held through the handshake must not be started or committed.
    @Test func localUtteranceHeldWhileConnectingIsDroppedByMute() async {
        let rig = SessionRig(.local)
        await rig.say("held")
        #expect(rig.opened == 1, "speech reopened the session")
        let press = rig.mark
        rig.session.setMuted(true)
        await rig.serverUp()
        expectNothingLeft(rig, since: press)
        #expect(rig.types(since: press).contains("input.clear"), "what the provider buffered is dropped")
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
