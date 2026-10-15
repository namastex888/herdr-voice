import Foundation
import Testing
@testable import HerdrVoiceCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// Drives a machine through (event, time) steps and returns every effect, in order.
private func run(_ machine: inout TurnTaking, _ steps: [(TurnTaking.Event, TimeInterval)]) -> [TurnTaking.Effect] {
    steps.flatMap { machine.handle($0.0, at: at($0.1)) }
}

// MARK: taps

@Test func aTapPrewarmsOnTheKeyAndOpensOnRelease() {
    var m = TurnTaking()
    #expect(m.handle(.keyDown, at: at(0)) == [.prewarm])
    #expect(m.handle(.keyUp, at: at(0.15)) == [.open])
    #expect(m.phase == .listening(heard: false, since: at(0.15)))
}

@Test func anotherKeyWhileDownCancelsAndNeverOpens() {
    var m = TurnTaking()
    let effects = run(&m, [(.keyDown, 0), (.otherKey, 0.1), (.otherKey, 0.12), (.keyUp, 0.2)])
    #expect(effects == [.prewarm, .cancelPrewarm])
    #expect(m.phase == .idle)
}

@Test func aLongHoldIsNotATap() {
    var m = TurnTaking()
    #expect(run(&m, [(.keyDown, 0), (.keyUp, 2)]) == [.prewarm, .cancelPrewarm])
    #expect(m.phase == .idle)
}

@Test func tappingAgainWithNothingSaidDismisses() {
    var m = TurnTaking()
    #expect(run(&m, [(.keyDown, 0), (.keyUp, 0.1), (.keyDown, 2), (.keyUp, 2.1)]) == [.prewarm, .open, .close])
    #expect(m.phase == .idle)
}

@Test func aDoubleTapIsHandsFreeUntilAnotherDoubleTap() {
    var m = TurnTaking()
    #expect(run(&m, [(.keyDown, 0), (.keyUp, 0.1), (.keyDown, 0.25), (.keyUp, 0.3)]) == [.prewarm, .open])
    #expect(m.handsFree)
    // Hands-free: speech, cooldown, reply, and back to listening with no follow-up countdown.
    #expect(run(&m, [(.speechStarted, 1), (.speechStopped, 3), (.tick, 3.6)]) == [.submit])
    _ = run(&m, [(.assistant(busy: true), 4), (.assistant(busy: false), 9)])
    #expect(m.phase == .listening(heard: false, since: at(9)))
    #expect(run(&m, [(.tick, 60)]).isEmpty) // never times out
    // A single tap doesn't end it (it would be the first half of the double tap); the double tap does.
    #expect(run(&m, [(.tap, 61)]).isEmpty)
    #expect(run(&m, [(.tap, 61.2)]) == [.close])
    #expect(!m.handsFree && m.phase == .idle)
}

@Test func theWakeWordOpensLikeATap() {
    var m = TurnTaking()
    #expect(m.handle(.tap, at: at(0)) == [.open])
    #expect(m.phase == .listening(heard: false, since: at(0)))
}

// MARK: speech, cooldown and reply

@Test func speechThenSilenceSubmitsAfterTheCooldown() {
    var m = TurnTaking()
    _ = run(&m, [(.tap, 0), (.speechStarted, 0.5), (.speechStopped, 2)])
    #expect(m.phase == .cooldown(since: at(2), until: at(2.5)))
    #expect(m.cooldownProgress(at: at(2.25)) == 0.5)
    #expect(run(&m, [(.tick, 2.4)]).isEmpty)
    #expect(run(&m, [(.tick, 2.5)]) == [.submit])
    #expect(m.phase == .replying(since: at(2.5)))
}

@Test func speechResumingInTheCooldownCancelsIt() {
    var m = TurnTaking()
    _ = run(&m, [(.tap, 0), (.speechStarted, 0.5), (.speechStopped, 2), (.speechStarted, 2.3)])
    #expect(m.phase == .listening(heard: true, since: at(2.3)))
    #expect(run(&m, [(.tick, 2.6), (.tick, 5)]).isEmpty) // nothing was submitted
    #expect(run(&m, [(.speechStopped, 6), (.tick, 6.5)]) == [.submit])
}

@Test func aTapInTheCooldownSubmitsAtOnce() {
    var m = TurnTaking()
    _ = run(&m, [(.tap, 0), (.speechStarted, 0.5), (.speechStopped, 2)])
    #expect(run(&m, [(.tap, 2.1)]) == [.submit])
}

@Test func withoutACooldownTheTurnGoesWhenSpeechStops() {
    var m = TurnTaking(timing: .init(cooldown: 0)) // Gemini answers by itself
    #expect(run(&m, [(.tap, 0), (.speechStarted, 0.5), (.speechStopped, 2)]) == [.open, .submit])
}

@Test func tappingWhileSheSpeaksBargesIn() {
    var m = TurnTaking()
    _ = run(&m, [(.tap, 0), (.speechStarted, 0.5), (.speechStopped, 2), (.tick, 2.5), (.assistant(busy: true), 3)])
    #expect(run(&m, [(.keyDown, 4), (.keyUp, 4.1)]) == [.bargeIn])
    #expect(m.phase == .listening(heard: false, since: at(4.1)))
}

// MARK: follow-up and closing

@Test func theFollowUpWindowLetsYouTalkThenClosesTheSession() {
    var m = TurnTaking(timing: .init(followUp: 8))
    _ = run(&m, [(.tap, 0), (.speechStarted, 0.5), (.speechStopped, 2), (.tick, 2.5),
                 (.assistant(busy: true), 3), (.assistant(busy: false), 6)])
    #expect(m.phase == .followUp(since: at(6), until: at(14)))
    #expect(m.followUpRemaining(at: at(8)) == 0.75)
    // Talking in the window needs no key.
    #expect(run(&m, [(.speechStarted, 9)]).isEmpty)
    #expect(m.phase == .listening(heard: true, since: at(9)))
    _ = run(&m, [(.speechStopped, 10), (.tick, 10.5), (.assistant(busy: true), 11), (.assistant(busy: false), 12)])
    #expect(run(&m, [(.tick, 19.9)]).isEmpty)
    #expect(run(&m, [(.tick, 20)]) == [.close]) // expired: the session closes so billing stops
    #expect(m.phase == .idle)
}

@Test func escOrThatsAllCloses() {
    var m = TurnTaking()
    _ = run(&m, [(.tap, 0), (.speechStarted, 0.5)])
    #expect(m.handle(.dismiss, at: at(1)) == [.close])
    #expect(m.handle(.dismiss, at: at(2)).isEmpty) // nothing left to close
}

@Test func saidNothingAfterATapLetsGo() {
    var m = TurnTaking(timing: .init(listenTimeout: 10))
    _ = m.handle(.tap, at: at(0))
    #expect(run(&m, [(.tick, 9)]).isEmpty)
    #expect(run(&m, [(.tick, 10)]) == [.close])
}

@Test func aReplyThatNeverComesStillEndsInTheFollowUp() {
    var m = TurnTaking(timing: .init(followUp: 8, replyTimeout: 20))
    _ = run(&m, [(.tap, 0), (.speechStarted, 0.5), (.speechStopped, 2), (.tick, 2.5)])
    #expect(run(&m, [(.tick, 22.5)]).isEmpty)
    #expect(m.phase == .followUp(since: at(22.5), until: at(30.5)))
}

@Test func herOwnReportOpensTheConversation() {
    var m = TurnTaking()
    #expect(m.handle(.assistant(busy: true), at: at(0)) == [.open])
    _ = m.handle(.assistant(busy: false), at: at(4))
    #expect(m.phase == .followUp(since: at(4), until: at(12)))
}

@Test func aResetForgetsTheTurnQuietly() {
    var m = TurnTaking()
    _ = run(&m, [(.keyDown, 0), (.keyUp, 0.1), (.keyDown, 0.2), (.keyUp, 0.3)])
    #expect(m.handle(.reset, at: at(1)).isEmpty)
    #expect(m.phase == .idle && !m.handsFree)
}

// MARK: the key itself

@Test func theTapFollowsTheRightCommandKeyOnly() {
    var tap = ModifierTap(key: .rightCommand)
    let command: UInt64 = 0x10_0000, right: UInt64 = 0x10, left: UInt64 = 0x08
    #expect(tap.flagsChanged(keyCode: 0x37, flags: command | left) == nil) // left ⌘ isn't ours
    #expect(tap.flagsChanged(keyCode: 0x37, flags: 0) == nil)
    #expect(tap.flagsChanged(keyCode: 0x36, flags: command | right) == .keyDown)
    #expect(tap.keyPressed() == .otherKey) // ⌘C
    #expect(tap.flagsChanged(keyCode: 0x36, flags: 0) == .keyUp)
    #expect(tap.keyPressed() == nil)
}

@Test func anotherModifierJoiningMakesAChord() {
    var tap = ModifierTap(key: .rightCommand)
    #expect(tap.flagsChanged(keyCode: 0x36, flags: 0x10_0010) == .keyDown)
    #expect(tap.flagsChanged(keyCode: 0x38, flags: 0x10_0010 | 0x02_0002) == .otherKey) // ⇧ joins: ⌘⇧4 coming
    // Left ⌘ held while right ⌘ goes up still reads as our key's release.
    #expect(tap.flagsChanged(keyCode: 0x36, flags: 0x10_0008) == .keyUp)
}

@Test func otherActivationKeysUseTheirOwnCodes() {
    var tap = ModifierTap(key: .rightOption)
    #expect(tap.flagsChanged(keyCode: 0x36, flags: 0x10_0010) == nil)
    #expect(tap.flagsChanged(keyCode: 0x3D, flags: 0x08_0040) == .keyDown)
    #expect(tap.flagsChanged(keyCode: 0x3D, flags: 0) == .keyUp)
    #expect(Set(ActivationKey.allCases.map(\.keyCode)).count == ActivationKey.allCases.count)
}

// MARK: phrases

@Test func theWakePhraseIsHeardInARunningTranscript() {
    #expect(WakePhrase.matches("okay so hey companion", phrase: "Hey Companion"))
    #expect(WakePhrase.matches("Hi, Companion!", phrase: "Hey Companion"))
    #expect(WakePhrase.matches("a companion", phrase: "Hey Companion"))
    #expect(!WakePhrase.matches("my companion app", phrase: "Hey Companion"))
    #expect(!WakePhrase.matches("hey", phrase: "Hey Companion"))
    #expect(WakePhrase.matches("ok jarvis", phrase: "OK Jarvis"))
}

@Test func thatsAllEndsAConversation() {
    #expect(DismissPhrase.matches("That's all, thanks."))
    #expect(DismissPhrase.matches("ok that’s all for now"))
    #expect(!DismissPhrase.matches("open all my windows"))
    #expect(!DismissPhrase.matches("is that all the files in the folder you found when you looked earlier today"))
}
