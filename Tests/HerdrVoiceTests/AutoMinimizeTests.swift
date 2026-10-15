import Foundation
import Testing
@testable import HerdrVoiceCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// The rule behind a reference, so `#expect` can feed it events.
private final class Rig {
    var rule = AutoMinimize()
    func handle(_ event: AutoMinimize.Event) -> Bool { rule.handle(event) }
    var isOpen: Bool { rule.isOpen }
    var reason: AutoMinimize.Reason? { rule.reason }
    var touched: Bool { rule.touched }
}

@Test func aShownResultGoesAwayAboutFourSecondsAfterSheStopsTalking() {
    let rule = Rig()
    _ = rule.handle(.opened(.shown, at: at(0)))
    // She's still talking about it: it stays however long that takes.
    #expect(!rule.handle(.tick(at(1), busy: true, questionPending: false)))
    #expect(!rule.handle(.tick(at(9), busy: true, questionPending: false)))
    #expect(!rule.handle(.tick(at(10), busy: false, questionPending: false)))
    #expect(!rule.handle(.tick(at(13.5), busy: false, questionPending: false)))
    #expect(rule.handle(.tick(at(14.1), busy: false, questionPending: false)))
    #expect(!rule.isOpen)
}

@Test func touchingTheShownResultKeepsItUp() {
    let rule = Rig()
    _ = rule.handle(.opened(.shown, at: at(0)))
    _ = rule.handle(.interacted)
    #expect(!rule.handle(.tick(at(30), busy: false, questionPending: false)))
    // The conversation ending doesn't take it from under the user either.
    #expect(!rule.handle(.conversationEnded))
    #expect(rule.isOpen)
}

@Test func theConversationEndingPutsAwayWhatSheOpened() {
    let rule = Rig()
    _ = rule.handle(.opened(.shown, at: at(0)))
    #expect(rule.handle(.conversationEnded))
    // Nothing up: nothing to put away.
    #expect(!rule.handle(.conversationEnded))
}

@Test func whatTheUserOpenedStaysWhenTheConversationEnds() {
    let rule = Rig()
    _ = rule.handle(.opened(.user, at: at(0)))
    #expect(!rule.handle(.conversationEnded))
    #expect(!rule.handle(.tick(at(60), busy: false, questionPending: false)))
}

@Test func anotherAppTakingFocusPutsItAwayEvenWhenTheUserOpenedIt() {
    let rule = Rig()
    _ = rule.handle(.opened(.user, at: at(0)))
    _ = rule.handle(.interacted)
    #expect(rule.handle(.focusLost))
    let shown = Rig()
    _ = shown.handle(.opened(.shown, at: at(0)))
    #expect(shown.handle(.focusLost))
}

@Test func aQuestionWaitingForYesKeepsThePhoneUpUntilAnswered() {
    let rule = Rig()
    _ = rule.handle(.opened(.question, at: at(0)))
    #expect(!rule.handle(.tick(at(1), busy: false, questionPending: true)))
    #expect(!rule.handle(.conversationEnded))
    #expect(!rule.handle(.focusLost))
    #expect(!rule.handle(.tick(at(20), busy: false, questionPending: true)))
    // Answered: what's left is a result, gone a few seconds later.
    #expect(!rule.handle(.tick(at(21), busy: false, questionPending: false)))
    #expect(rule.handle(.tick(at(25.5), busy: false, questionPending: false)))
}

@Test func herQuestionOutranksAShownResultButNotTheUser() {
    let rule = Rig()
    _ = rule.handle(.opened(.shown, at: at(0)))
    _ = rule.handle(.opened(.question, at: at(1)))
    #expect(rule.reason == .question)
    let user = Rig()
    _ = user.handle(.opened(.user, at: at(0)))
    _ = user.handle(.opened(.question, at: at(1)))
    #expect(user.reason == .user)
}

@Test func collapsingByHandForgetsWhyItWasUp() {
    let rule = Rig()
    _ = rule.handle(.opened(.shown, at: at(0)))
    _ = rule.handle(.interacted)
    _ = rule.handle(.collapsed)
    #expect(!rule.isOpen && !rule.touched)
    _ = rule.handle(.opened(.shown, at: at(10)))
    #expect(rule.handle(.conversationEnded))
}
