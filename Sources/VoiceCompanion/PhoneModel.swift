import AppKit
import HerdrVoiceCore
import SwiftUI

/// What the phone's screen shows.
enum PhoneScreen: Hashable {
    /// The clock and what came in: where a conversation started by voice opens.
    case lock
    case home
    /// The voice chat: the current conversation as voice notes.
    case messages
    /// The kept conversations, and one of them by id.
    case conversations
    case conversation(String)
    case settings
    /// What she controls, what she knows, how she changed.
    case skills
    /// One harness or learned skill, by entry id: its app.
    case app(String)
    /// A cockpit widget's chart of its day-by-day evolution.
    case detail(DashboardItem)

    /// The screens the voice and the self-test name: these, and each widget's chart by the widget's id.
    static let named: [String: PhoneScreen] = {
        var named: [String: PhoneScreen] = [
            "lock": .lock, "home": .home, "cockpit": .home, "messages": .messages, "chat": .messages,
            "conversations": .conversations, "settings": .settings, "skills": .skills,
        ]
        for item in DashboardItem.allCases where item.isWidget { named[item.rawValue] = .detail(item) }
        return named
    }()
}

/// The phone's own state: which screen, whether the shade is down, and how far the orb has grown into the phone.
@MainActor final class PhoneModel: ObservableObject {
    @Published var screen: PhoneScreen = .home
    @Published var shadeOpen = false
    /// 0 is the orb, 1 the phone; animated between, so a value in between is a frame of the morph.
    @Published var morph: CGFloat = 0
    /// Where it is going: the phone (true) or the orb.
    @Published var expanded = false
    @Published var theme = PhoneTheme()

    func go(_ next: PhoneScreen) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            shadeOpen = false
            screen = next
        }
    }
}

/// What changes many times a second (the mic and voice levels, the orb's clock, the cooldown and the follow-up
/// countdown). Only the orb and the light bar watch it, so the rest of the phone isn't redrawn with it.
@MainActor final class LiveLevels: ObservableObject {
    /// The orb's look: the session's mood, or resting between conversations.
    enum Look: Equatable {
        case resting
        case mood(Mood)
    }

    struct Frame: Equatable {
        var look = Look.resting
        /// Smoothed 0...1 loudness: yours and hers.
        var mic: Double = 0
        var voice: Double = 0
        var thinking = false
        /// A conversation is open and she listens: the orb wears its listening glow.
        var listening = false
        /// Advances faster with the mood's liveliness and with voice: the orb's blobs and the light bar move with it.
        var time: Double = 0
        /// While the cooldown runs, how far (0...1); while the follow-up window runs, how much is left (1...0).
        var cooldown: Double?
        var followUp: Double?
    }

    @Published private(set) var frame = Frame()
    private var last = CACurrentMediaTime()

    /// Raw levels in, smoothed like the plugin's orb: a fourth root lifts quiet speech, fast attack and slow release
    /// feel like breath, not flicker.
    func update(look: Look, mic: Float, voice: Float, thinking: Bool, listening: Bool, cooldown: Double?,
                followUp: Double?) {
        let now = CACurrentMediaTime(), dt = min(now - last, 0.1)
        last = now
        var next = frame
        next.look = look
        next.mic = Self.smooth(frame.mic, toward: mic)
        next.voice = Self.smooth(frame.voice, toward: voice)
        next.thinking = thinking
        next.listening = listening
        let speed = switch look {
        case .resting: 0.25
        case .mood(let mood): mood.idleSpeed
        }
        next.time += dt * (speed + next.mic * 2.2 + next.voice * 1.4)
        next.cooldown = cooldown
        next.followUp = followUp
        if next != frame { frame = next }
    }

    /// A fixed frame, for rendering the phone to an image.
    func show(_ fixed: Frame) { frame = fixed }

    private static func smooth(_ current: Double, toward level: Float) -> Double {
        let target = pow(min(max(Double(level) * 6, 0), 1), 0.25)
        return current + (target - current) * (target > current ? 0.35 : 0.05)
    }
}
