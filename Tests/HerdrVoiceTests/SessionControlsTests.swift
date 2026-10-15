import Testing
@testable import HerdrVoiceCore

private func controls(_ link: SessionControls.Link = .connected, muted: Bool = false, paused: Bool = false,
                      speaking: Bool = false) -> SessionControls {
    SessionControls(available: true, link: link, muted: muted, paused: paused, speaking: speaking)
}

private func mood(_ c: SessionControls, agentsWorking: Bool = false) -> Mood {
    Activity.mood(controls: c, loading: false, agentsWorking: agentsWorking, micQuiet: true)
}

@Test func theLinkFollowsTheSessionsFlags() {
    #expect(SessionControls.link(open: true, dormant: false, disconnectedByUser: false) == .connected)
    #expect(SessionControls.link(open: false, dormant: true, disconnectedByUser: false) == .idle)
    #expect(SessionControls.link(open: false, dormant: false, disconnectedByUser: false) == .offline)
    // The user's disconnect outranks everything, including a dormant flag left behind.
    #expect(SessionControls.link(open: false, dormant: true, disconnectedByUser: true) == .disconnected)
}

@Test func theStateNamesTheMostBindingHold() {
    #expect(controls().state == "Connected")
    #expect(controls(.idle).state == "Idle")
    #expect(controls(.offline).state == "Offline")
    #expect(controls(muted: true).state == "Muted")
    #expect(controls(muted: true, paused: true).state == "Paused")
    #expect(controls(.disconnected, muted: true, paused: true).state == "Disconnected")
    #expect(SessionControls().state == "No session")
}

@Test func theDetailMentionsEveryHold() {
    let detail = controls(.idle, muted: true, paused: true).detail
    #expect(detail.contains("closed while it's quiet") && detail.contains("Paused") && detail.contains("Muted"))
}

@Test func eachControlIsTitledForWhatItWouldDo() {
    #expect(controls().muteTitle == "Mute" && controls(muted: true).muteTitle == "Unmute")
    #expect(controls().pauseTitle == "Pause" && controls(paused: true).pauseTitle == "Resume")
    // Open, or closed only until you speak: Disconnect, so it stays closed.
    #expect(controls().connectTitle == "Disconnect" && controls(.idle).connectTitle == "Disconnect")
    // Offline or disconnected: Connect, which opens the session now.
    #expect(controls(.offline).connectTitle == "Connect" && controls(.disconnected).connectTitle == "Connect")
    #expect(controls(muted: true).muteSymbol == "mic.slash.fill" && controls(paused: true).pauseSymbol == "play.fill")
}

@Test func stopSpeakingOnlyWhileTheVoiceIsAudible() {
    #expect(!controls().canStopSpeaking)
    #expect(controls(speaking: true).canStopSpeaking)
    #expect(!SessionControls(speaking: true).canStopSpeaking) // no session to stop
}

@Test func theMicListensOnlyWithNothingHoldingIt() {
    #expect(controls().listening && controls(.idle).listening)
    #expect(!controls(muted: true).listening)
    #expect(!controls(paused: true).listening)
    #expect(!controls(.disconnected).listening)
    #expect(!SessionControls().listening)
}

@Test func aDisconnectShowsOfflineEvenWhileMuted() {
    #expect(mood(controls(.disconnected)) == .offline)
    #expect(mood(controls(.disconnected, muted: true)) == .offline)
    #expect(mood(controls(.disconnected, paused: true)) == .offline)
    #expect(mood(SessionControls()) == .offline)
}

@Test func aPauseShowsMutedEvenOverSpeechOrWork() {
    #expect(mood(controls(paused: true)) == .muted)
    #expect(mood(controls(paused: true, speaking: true)) == .muted)
    #expect(mood(controls(paused: true), agentsWorking: true) == .muted)
    #expect(mood(controls(.idle, paused: true)) == .muted)
}

@Test func withoutHoldsTheMoodIsTheUsualOne() {
    #expect(mood(controls()) == .listening)
    #expect(mood(controls(speaking: true)) == .speaking)
    #expect(mood(controls(.idle)) == .listening)  // closed on purpose while quiet isn't red
    #expect(mood(controls(.offline)) == .offline)
    #expect(mood(controls(muted: true, speaking: true)) == .speaking) // muted still lets the voice talk
}

@Test func aPauseHoldsEveryReport() {
    for live in [true, false] {
        for disconnected in [true, false] {
            for byUser in [true, false] {
                #expect(ReportDelivery.route(paused: true, live: live, disconnected: disconnected,
                                             disconnectedByUser: byUser) == .hold)
            }
        }
    }
}

@Test func reportsReopenOnlyASessionTheUserDidNotClose() {
    #expect(ReportDelivery.route(paused: false, live: true, disconnected: false, disconnectedByUser: false) == .send)
    #expect(ReportDelivery.route(paused: false, live: false, disconnected: true, disconnectedByUser: false)
        == .holdAndConnect)
    #expect(ReportDelivery.route(paused: false, live: false, disconnected: true, disconnectedByUser: true) == .hold)
    // Opening but not yet established: it waits for the session that is on its way.
    #expect(ReportDelivery.route(paused: false, live: false, disconnected: false, disconnectedByUser: false) == .hold)
}

@Test func aWithheldReplyGoesOutOnResume() {
    var replies = ResponseScheduler()
    let taken = replies.wantReply() // the session would send response.create now
    replies.withhold()              // but it's paused
    #expect(taken && !replies.responseActive && replies.replyWanted)
    let resumed = replies.resume()
    #expect(resumed && replies.responseActive && !replies.replyWanted)
}

@Test func aWithheldReplyStillWaitsForCallsInFlight() {
    var replies = ResponseScheduler()
    _ = replies.wantReply()
    replies.withhold()
    replies.callStarted()
    let early = replies.resume() // a call from the paused turn is still running
    let afterCall = replies.callFinished()
    #expect(!early && afterCall)
}
