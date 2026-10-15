import Foundation

/// When the phone goes back into the orb by itself. In voice mode a tap only lights the orb; the phone rises when
/// she shows something (`show`), asks for a yes, or the user opens it. It goes away again:
/// - when the conversation ends (the follow-up window closed and nothing pending), unless the user has used it;
/// - when another app takes focus;
/// - about `resultLinger` seconds after a shown result, once she has stopped talking, unless the user interacts.
/// A question waiting for the user's yes keeps it up through all three; the gesture bar and Esc always put it away
/// (the controller does that directly, not through here).
public struct AutoMinimize: Equatable, Sendable {
    /// Why the phone is up.
    public enum Reason: Equatable, Sendable {
        /// The user opened it (a click, the menu).
        case user
        /// She showed a screen (`show_screen`): a list, a link, a result.
        case shown
        /// She asks for the user's yes.
        case question
    }

    public enum Event: Equatable, Sendable {
        case opened(Reason, at: Date)
        /// A click, a scroll or a key in the phone (hovering doesn't count).
        case interacted
        /// Another app became the active one.
        case focusLost
        /// The conversation is over: the follow-up window closed and nothing is pending.
        case conversationEnded
        /// Each frame: whether she is still busy with the turn (speaking, replying, a tool running), and whether a
        /// question waits for the user's yes.
        case tick(Date, busy: Bool, questionPending: Bool)
        /// The phone went back into the orb, whoever did it.
        case collapsed
    }

    /// After a shown result, how long it stays once she's quiet.
    public static let resultLinger: TimeInterval = 4

    /// Why it's up, or nil while it's the orb.
    public private(set) var reason: Reason?
    /// The user has clicked, scrolled or typed in it since it opened.
    public private(set) var touched = false
    /// When she last stopped being busy while a shown result was up.
    public private(set) var quietSince: Date?
    public private(set) var questionPending = false

    public init() {}

    public var isOpen: Bool { reason != nil }

    /// Feeds one event; true means put the phone away now.
    public mutating func handle(_ event: Event) -> Bool {
        switch event {
        case .opened(let why, let at):
            // Already up: the user's own opening wins; her question outranks a shown result.
            switch (reason, why) {
            case (nil, _), (.shown?, .question), (_, .user): reason = why
            default: break
            }
            if why == .user { touched = true }
            if reason == .shown { quietSince = at } else { quietSince = nil }
            return false
        case .interacted:
            guard reason != nil else { return false }
            touched = true
            return false
        case .focusLost:
            return close(if: reason != nil && !questionPending)
        case .conversationEnded:
            return close(if: reason != nil && !touched && !questionPending)
        case .tick(let now, let busy, let pending):
            questionPending = pending
            // Her question answered: what's left on screen is a result like any other.
            if reason == .question && !pending { reason = .shown }
            guard reason == .shown, !touched else { return false }
            if busy || pending {
                quietSince = nil
                return false
            }
            let since = quietSince ?? now
            quietSince = since
            return close(if: now.timeIntervalSince(since) >= Self.resultLinger)
        case .collapsed:
            reset()
            return false
        }
    }

    private mutating func close(if condition: Bool) -> Bool {
        guard condition else { return false }
        reset()
        return true
    }

    private mutating func reset() {
        reason = nil
        touched = false
        quietSince = nil
    }
}
