import AppKit
import CoreGraphics
import HerdrVoiceCore

/// Watches the activation key in every app through a listen-only event tap: it sees key events and never changes or
/// swallows them, so ⌘C still copies. That needs Input Monitoring (Privacy & Security), which macOS asks for once;
/// Accessibility (what a global NSEvent monitor needs) would also let an app control the Mac, which this doesn't.
/// Without it the companion falls back to the on-screen mic button (⌥⌘M is Mute, always). `ModifierTap` decides
/// what each event means.
@MainActor final class ActivationKeyMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var state: ModifierTap
    private let onEvent: (ModifierTap.Event) -> Void

    init(key: ActivationKey, onEvent: @escaping (ModifierTap.Event) -> Void) {
        state = ModifierTap(key: key)
        self.onEvent = onEvent
    }

    /// Input Monitoring is granted.
    static var permitted: Bool { CGPreflightListenEventAccess() }

    /// Asks for Input Monitoring: macOS shows its prompt the first time, then only System Settings can grant it.
    @discardableResult static func requestPermission() -> Bool { CGRequestListenEventAccess() }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    var key: ActivationKey {
        get { state.key }
        set { state = ModifierTap(key: newValue) }
    }

    var running: Bool { tap != nil }

    /// Starts watching; false when Input Monitoring isn't granted (or the tap can't be made).
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.permitted else { return false }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, info in
            // The tap's run loop source is on the main run loop, so this runs on main.
            if let info {
                let monitor = Unmanaged<ActivationKeyMonitor>.fromOpaque(info).takeUnretainedValue()
                let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags.rawValue
                MainActor.assumeIsolated { monitor.received(type, keyCode: keyCode, flags: flags) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
        state = ModifierTap(key: state.key)
    }

    private func received(_ type: CGEventType, keyCode: UInt16, flags: UInt64) {
        let event: ModifierTap.Event?
        switch type {
        case .flagsChanged: event = state.flagsChanged(keyCode: keyCode, flags: flags)
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown: event = state.keyPressed() // ⌘C, ⌘-click
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off; ours only listens, so turn it straight back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            event = nil
        default: event = nil
        }
        if let event { onEvent(event) }
    }
}
