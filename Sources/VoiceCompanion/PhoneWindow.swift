import AppKit
import HerdrVoiceCore
import SwiftUI

/// A panel that can take typing (Messages, Settings). Clicking it activates the app; a conversation started by voice
/// shows it without taking focus from the app you're in.
final class PhonePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click even while the app is in the background, so one click on the orb opens the phone.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The companion's one window: the orb in the bottom-right corner of the active screen, which grows into the phone
/// and shrinks back. While it's the orb the window is just the orb's size, so it covers nothing else; to open, the
/// window takes the phone's size first (the orb stays put: everything is anchored at the bottom-right corner) and
/// then the shape grows; to close, the shape shrinks back and the window follows once it's the orb again.
@MainActor final class PhoneWindow {
    static let orbDiameter: CGFloat = 60
    /// Pixel proportions, about 9:19.5.
    static let phoneSize = CGSize(width: 300, height: 650)
    static let cornerRadius: CGFloat = 46
    static let bezel: CGFloat = 6
    /// Room around the shape for the orb's glow and the phone's shadow.
    static let pad: CGFloat = 30
    /// From the screen's visible edges.
    static let margin: CGFloat = 14
    /// Above every app window, the Dock and full-screen Spaces, like the plugin's orb.
    static let level: NSWindow.Level = .popUpMenu
    static let opening = Animation.spring(response: 0.55, dampingFraction: 0.78)
    static let closing = Animation.spring(response: 0.42, dampingFraction: 0.92)

    let panel: PhonePanel
    let model: PhoneModel
    private var hint: NSPanel?

    init(model: PhoneModel, content: some View) {
        self.model = model
        panel = PhonePanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI draws the phone's own
        panel.level = Self.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.contentView = FirstClickHostingView(rootView: content)
        place()
        // Displays come and go: keep the orb in the corner of a screen that exists.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    var isExpanded: Bool { model.expanded }

    func showOrb() {
        place()
        panel.orderFrontRegardless()
    }

    /// The bottom-right corner both shapes share, on the screen the mouse is on.
    private func anchor() -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - Self.margin, y: visible.minY + Self.margin)
    }

    private func frame(expanded: Bool, at anchor: NSPoint) -> NSRect {
        let size = expanded ? Self.phoneSize : CGSize(width: Self.orbDiameter, height: Self.orbDiameter)
        return NSRect(x: anchor.x + Self.pad - size.width - Self.pad * 2, y: anchor.y - Self.pad,
                      width: size.width + Self.pad * 2, height: size.height + Self.pad * 2)
    }

    /// Puts the window where its state says, at once.
    func place() {
        panel.setFrame(frame(expanded: model.expanded || model.morph > 0.001, at: anchor()), display: true)
    }

    /// Grows the orb into the phone on `screen`. `activate`: the user clicked, so the phone takes focus (typing
    /// works at once); a conversation started by voice leaves focus where it was.
    func expand(to screen: PhoneScreen?, activate: Bool) {
        hideHint()
        if let screen, screen != model.screen { model.screen = screen }
        if !model.expanded {
            model.expanded = true
            panel.setFrame(frame(expanded: true, at: anchor()), display: true)
            panel.orderFrontRegardless()
            withAnimation(Self.opening) { model.morph = 1 }
        }
        if activate {
            NSApp.activate()
            panel.makeKey()
        }
    }

    /// Shrinks the phone back into the orb; the window follows once it's the orb again.
    func collapse() {
        guard model.expanded else { return }
        model.expanded = false
        model.shadeOpen = false
        if panel.isKeyWindow { NSApp.deactivate() } // give focus back to the app you were in
        withAnimation(Self.closing, completionCriteria: .logicallyComplete) {
            model.morph = 0
        } completion: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.expanded else { return }
                self.panel.setFrame(self.frame(expanded: false, at: self.anchor()), display: true)
            }
        }
    }

    // MARK: first-run hint

    /// A small bubble beside the orb with how to talk, on first run only.
    func showHint(_ text: String) {
        guard hint == nil else { return }
        let label = NSHostingView(rootView: HintBubble(text: text).environment(\.phoneTheme, model.theme))
        let size = label.fittingSize
        let bubble = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        bubble.level = Self.level
        bubble.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        bubble.ignoresMouseEvents = true
        bubble.contentView = label
        let a = anchor()
        bubble.setFrameOrigin(NSPoint(x: a.x - Self.orbDiameter - 12 - size.width,
                                      y: a.y + Self.orbDiameter / 2 - size.height / 2))
        bubble.orderFrontRegardless()
        hint = bubble
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.hideHint() }
    }

    func hideHint() {
        hint?.orderOut(nil)
        hint = nil
    }
}

private struct HintBubble: View {
    let text: String
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Text(text).font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.onPrimaryContainer)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(theme.primaryContainer))
            .overlay(Capsule().strokeBorder(theme.primary.opacity(0.4), lineWidth: 1))
            .padding(6)
            .preferredColorScheme(.dark)
    }
}
