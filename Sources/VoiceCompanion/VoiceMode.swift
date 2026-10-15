import AppKit
import HerdrVoiceCore
import VoiceEngine

/// Voice mode: a tap lights the orb, and the phone rises only when she has something to show or a question for the
/// user. `AutoMinimize` decides when it goes back into the orb; this feeds it the app's events and the clock.
extension CompanionController {
    /// Another app taking focus, and clicks, scrolls and keys in the phone (hovering doesn't count as using it).
    func watchFocusAndTouches() {
        let workspace = NSWorkspace.shared.notificationCenter
        voiceModeObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                        object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != getpid() else { return }
            MainActor.assumeIsolated { self?.otherAppFocused() }
        })
        let touches: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: touches, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.phoneWindow?.panel { self.phoneTouched() }
            }
            return event
        }) {
            voiceModeObservers.append(monitor)
        }
    }

    func otherAppFocused() {
        if minimizer.handle(.focusLost) { minimize() }
    }

    func phoneTouched() {
        _ = minimizer.handle(.interacted)
    }

    /// Each frame: a shown result goes a few seconds after she's done with it. `busy` overrides whether she is still
    /// on the turn (the self-test's fake clock).
    func tickMinimizer(at now: Date, busy: Bool? = nil) {
        let busy = busy ?? (chat.controls.speaking || (session?.replying ?? false))
        if minimizer.handle(.tick(now, busy: busy, questionPending: gate.pendingAction != nil)) { minimize() }
    }

    /// Back into the orb by the rules (the minimizer has already forgotten why it was up).
    func minimize() {
        syncPhoneReason()
        phoneWindow?.collapse()
    }

    func syncPhoneReason() {
        if phoneReason != minimizer.reason { phoneReason = minimizer.reason }
    }

    /// What the session said that needs the user: a question waiting for their yes opens the conversation.
    func sessionSaid(_ event: SessionEvent) {
        guard case .toolResult(_, let output) = event, ChatModel.question(in: output) != nil else { return }
        openPhone(.messages, activate: false, reason: .question)
    }
}
