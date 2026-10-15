import AppKit
import HerdrVoiceCore
import SwiftUI

/// The phone's Material You colours, derived from one seed hue the way Android derives a dynamic scheme from the
/// wallpaper: a tonal palette per role (primary, secondary, tertiary, neutral), dark tones for surfaces and light
/// ones for what sits on them. Dark only: the phone floats over whatever is on screen.
struct PhoneTheme: Equatable {
    /// The seeds Settings offers, by the name kept in `settings.accent`.
    enum Seed: String, CaseIterable, Identifiable {
        case blue, violet, teal, green, amber, rose
        var id: String { rawValue }
        static let `default` = Seed.blue

        var hue: Double {
            switch self {
            case .blue: 0.60
            case .violet: 0.74
            case .teal: 0.50
            case .green: 0.38
            case .amber: 0.10
            case .rose: 0.95
            }
        }
    }

    let seed: Seed
    let primary: Color
    let onPrimary: Color
    let primaryContainer: Color
    let onPrimaryContainer: Color
    let secondaryContainer: Color
    let onSecondaryContainer: Color
    let tertiary: Color
    let tertiaryContainer: Color
    let onTertiaryContainer: Color
    let surface: Color
    let surfaceDim: Color
    let surfaceContainerLow: Color
    let surfaceContainer: Color
    let surfaceContainerHigh: Color
    let surfaceContainerHighest: Color
    let onSurface: Color
    let onSurfaceVariant: Color
    let outline: Color
    let outlineVariant: Color
    let error: Color
    let success: Color

    init(seed: Seed = .default) {
        self.seed = seed
        let h = seed.hue, t = (h + 0.18).truncatingRemainder(dividingBy: 1)
        func tone(_ hue: Double, _ chroma: Double, _ lightness: Double) -> Color {
            Self.hsl(hue, chroma, lightness)
        }
        primary = tone(h, 0.75, 0.80)
        onPrimary = tone(h, 0.70, 0.20)
        primaryContainer = tone(h, 0.45, 0.30)
        onPrimaryContainer = tone(h, 0.80, 0.90)
        secondaryContainer = tone(h, 0.18, 0.26)
        onSecondaryContainer = tone(h, 0.30, 0.90)
        tertiary = tone(t, 0.55, 0.78)
        tertiaryContainer = tone(t, 0.35, 0.28)
        onTertiaryContainer = tone(t, 0.70, 0.90)
        surface = tone(h, 0.10, 0.065)
        surfaceDim = tone(h, 0.10, 0.05)
        surfaceContainerLow = tone(h, 0.10, 0.09)
        surfaceContainer = tone(h, 0.10, 0.115)
        surfaceContainerHigh = tone(h, 0.10, 0.15)
        surfaceContainerHighest = tone(h, 0.10, 0.19)
        onSurface = tone(h, 0.12, 0.91)
        onSurfaceVariant = tone(h, 0.10, 0.76)
        outline = tone(h, 0.08, 0.56)
        outlineVariant = tone(h, 0.08, 0.30)
        error = Color(red: 1.0, green: 0.71, blue: 0.67)
        success = Color(red: 0.55, green: 0.86, blue: 0.62)
    }

    /// Google's four colours, for the assistant's light bar.
    static let assistantColors: [Color] = [
        Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.92, green: 0.26, blue: 0.21),
        Color(red: 0.98, green: 0.74, blue: 0.02), Color(red: 0.20, green: 0.66, blue: 0.33),
    ]

    /// HSL to a colour (hue, saturation and lightness in 0...1).
    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> Color {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch hp {
        case ..<1: (c, x, 0)
        case ..<2: (x, c, 0)
        case ..<3: (0, c, x)
        case ..<4: (0, x, c)
        case ..<5: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        return Color(red: r + m, green: g + m, blue: b + m)
    }
}

extension Mood {
    /// The orb's colours per mood, as the plugin's orb has them.
    var orbColors: [Color] {
        switch self {
        case .muted: [Color(nsColor: .systemGray), Color(nsColor: .darkGray), Color(nsColor: .lightGray)]
        case .listening: [Color(nsColor: .systemTeal), Color(nsColor: .systemBlue), Color(nsColor: .systemCyan)]
        case .speaking: [Color(nsColor: .systemPink), Color(nsColor: .systemPurple), Color(nsColor: .systemIndigo)]
        case .working: [Color(nsColor: .systemYellow), Color(nsColor: .systemOrange), Color(nsColor: .systemRed)]
        case .offline: [Color(nsColor: .systemRed), .black, Color(nsColor: .systemPink)]
        }
    }

    /// How lively the orb is with no voice at all.
    var idleSpeed: Double {
        switch self {
        case .muted, .offline: 0.15
        case .listening: 0.45
        case .speaking: 0.6
        case .working: 0.9
        }
    }
}

extension Color {
    /// This colour moved `amount` of the way to `other` (Color.mix needs macOS 15).
    func blend(_ other: NSColor, _ amount: Double) -> Color {
        let base = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return Color(nsColor: base.blended(withFraction: amount, of: other) ?? base)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = PhoneTheme()
}

/// Set while rendering the phone to an image (the self-test, `--render-phone`): views draw text fields and scroll
/// views as plain content, which an image renderer can draw.
private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var phoneTheme: PhoneTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }

    var phoneSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}
