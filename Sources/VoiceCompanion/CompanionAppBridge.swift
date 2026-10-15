import AppKit
import HerdrVoiceCore
import SwiftUI

/// Her app as the companion harness sees it. The harness runs on a tool's background thread; everything here that
/// touches the app hops to the main thread (or runs at once when already on it, as in the self-test).
final class CompanionAppBridge: CompanionApp, @unchecked Sendable {
    private let lock = NSLock()
    private weak var controllerRef: CompanionController?
    private weak var registryRef: SkillRegistry?

    @MainActor func attach(_ controller: CompanionController) {
        lock.withLock {
            controllerRef = controller
            registryRef = controller.registry
        }
    }

    var registry: SkillRegistry? { lock.withLock { registryRef } }
    var providers: [Provider] { CompanionKeys.providers }
    var provider: Provider { onMain { $0.provider } ?? .grok }

    func perform(_ action: CompanionHarness.AppAction) -> String {
        onMain { $0.perform(action) } ?? "error: her app isn't running"
    }

    private func onMain<T: Sendable>(_ work: @MainActor (CompanionController) -> T) -> T? {
        let controller = lock.withLock { controllerRef }
        guard let controller else { return nil }
        if Thread.isMainThread { return MainActor.assumeIsolated { work(controller) } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { work(controller) } }
    }
}

extension CompanionController {
    /// How long a Pause or Disconnect asked for by voice waits for her to finish saying so.
    static let deferredPressLimit: TimeInterval = 6

    /// One session or screen action asked for by voice, already through the harness's tiers. Mute applies at once
    /// (she can still talk); Pause and Disconnect wait until her reply saying so is over, or they'd cut it off.
    func perform(_ action: CompanionHarness.AppAction) -> String {
        guard session != nil || !Self.needsSession(action) else { return "error: there's no voice session yet." }
        switch action {
        case .mute(let on):
            press(.mute(on))
            return on ? "Done: the mic is off; I can still talk." : "Done: I can hear you again."
        case .pause:
            deferredPress = (.pause(true), Date().addingTimeInterval(Self.deferredPressLimit))
            return "Done: pausing as soon as you've heard this; Resume brings me back."
        case .resume:
            press(.pause(false))
            return "Done: resumed."
        case .disconnect:
            deferredPress = (.connect(false), Date().addingTimeInterval(Self.deferredPressLimit))
            return "Done: disconnecting as soon as you've heard this; tap or type to bring me back."
        case .stopSpeaking:
            stopSpeaking()
            return "Done."
        case .show(let name):
            if name == "shade" {
                openPhone(phone.expanded ? nil : .home, activate: false, reason: .shown)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { phone.shadeOpen = true }
            } else {
                openPhone(PhoneScreen.named[name] ?? .home, activate: false, reason: .shown)
            }
            return "Done: showing \(name)."
        case .collapse:
            collapsePhone()
            return "Done: back to the orb."
        }
    }

    private static func needsSession(_ action: CompanionHarness.AppAction) -> Bool {
        switch action {
        case .show, .collapse: false
        default: true
        }
    }

    /// Each frame: a deferred Pause or Disconnect goes once she's done speaking, or at its deadline.
    func runDeferredPress(at now: Date) {
        guard let pending = deferredPress else { return }
        guard !(session?.replying ?? false) || now >= pending.deadline else { return }
        deferredPress = nil
        press(pending.press)
    }
}
