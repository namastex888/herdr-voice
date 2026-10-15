import AppKit
import HerdrVoiceCore
import SwiftUI
import VoiceEngine

// The companion as a phone: the orb in the screen corner grows into an Android phone and shrinks back. One shape
// animates between the two (`MorphShell`); the phone has a lock screen, a home screen of her skills as apps,
// Messages, Skills and Settings, a notification shade with quick settings, and the assistant sheet that rises during
// a conversation.

/// The window's whole content: the orb or the phone, anchored at the bottom-right corner where the orb sits.
struct PhoneRoot: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var model: PhoneModel
    let live: LiveLevels
    let device: DeviceStatus

    var body: some View {
        MorphShell(morph: model.morph) {
            OrbButton(controller: controller, live: live)
        } phone: {
            PhoneBody(controller: controller, chat: controller.chat, model: model, live: live, device: device)
        }
        .padding(PhoneWindow.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .environment(\.phoneTheme, model.theme)
        .preferredColorScheme(.dark)
    }
}

/// One shape between the orb and the phone: at 0 a circle the orb's size, at 1 the phone's rounded rectangle, and
/// every frame in between grows from the orb's corner. The phone's screen scales with the shape's width, as an
/// Android app opens from its icon, and fades in while the orb fades out.
struct MorphShell<Orb: View, Phone: View>: View, Animatable {
    var morph: CGFloat
    let orb: Orb
    let phone: Phone

    init(morph: CGFloat, @ViewBuilder orb: () -> Orb, @ViewBuilder phone: () -> Phone) {
        self.morph = morph
        self.orb = orb()
        self.phone = phone()
    }

    nonisolated var animatableData: CGFloat {
        get { morph }
        set { morph = newValue }
    }

    var body: some View {
        let p = max(0, morph), d = PhoneWindow.orbDiameter, size = PhoneWindow.phoneSize
        let width = d + (size.width - d) * p, height = d + (size.height - d) * p
        let radius = min(d / 2 + (PhoneWindow.cornerRadius - d / 2) * min(p, 1), min(width, height) / 2)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let phoneShown = min(1, max(0, (p - 0.25) / 0.6))
        ZStack(alignment: .bottomTrailing) {
            if p > 0.001 {
                shape.fill(Color(red: 0.03, green: 0.03, blue: 0.045))
                    .frame(width: width, height: height)
                    .shadow(color: .black.opacity(0.5 * min(p, 1)), radius: 22 * min(p, 1), y: 8 * min(p, 1))
                phone
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(width / size.width, anchor: .bottomTrailing)
                    .frame(width: width, height: height, alignment: .bottomTrailing)
                    .clipShape(shape)
                    .opacity(phoneShown)
                    .allowsHitTesting(p > 0.95)
            }
            if p < 0.6 {
                orb
                    .scaleEffect(1 + p * 0.8)
                    .opacity(1 - p / 0.6)
                    .frame(width: d, height: d)
                    .allowsHitTesting(p < 0.05)
            }
        }
        .frame(width: max(width, d), height: max(height, d), alignment: .bottomTrailing)
    }
}

// MARK: the orb

/// The orb: click to open the phone, right-click for the session controls.
struct OrbButton: View {
    @ObservedObject var controller: CompanionController
    let live: LiveLevels

    var body: some View {
        OrbView(live: live, diameter: PhoneWindow.orbDiameter)
            .contentShape(Circle())
            .onTapGesture { controller.openPhone(.home, activate: true) }
            .contextMenu {
                Button(controller.phone.expanded ? "Hide phone" : "Show phone") { controller.togglePhone() }
                Divider()
                ForEach(Array(controller.controlChoices(syncing: false).enumerated()), id: \.offset) { _, choice in
                    Button(choice.title, action: choice.action).disabled(!choice.enabled)
                }
                Divider()
                Button("Settings…") { controller.openPhone(.settings, activate: true) }
                Button("Quit Voice Companion") { controller.quit() }
            }
            .help(controller.orbHelp)
    }
}

/// The plugin's orb redrawn for the companion: a glow, a sphere with three liquid blobs in the mood's colours that
/// stir with your voice and hers, a core that lights up while she speaks, and a soft highlight.
struct OrbView: View {
    @ObservedObject var live: LiveLevels
    let diameter: CGFloat
    @Environment(\.phoneTheme) private var theme

    private static let blobs: [(fx: (Double, Double), fy: (Double, Double), phase: Double, color: Int)] = [
        ((0.9, 1.7), (1.1, 1.3), 0, 0), ((1.3, 0.7), (0.8, 1.9), 2.1, 1), ((0.6, 1.1), (1.4, 0.9), 4.2, 2),
    ]

    var body: some View {
        let f = live.frame
        let colors = colors(f.look)
        let energy = max(f.mic, f.voice)
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let breathe = 0.03 * sin(f.time * 1.1)
            let r = diameter / 2 * (1 + breathe + energy * 0.12)
            // Glow
            let glowR = diameter * (0.72 + f.mic * 0.3 + f.voice * 0.18 + breathe)
            let dim = f.look == .mood(.muted) || f.look == .resting
            context.fill(Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR, width: glowR * 2, height: glowR * 2)),
                         with: .radialGradient(Gradient(colors: [colors[0].opacity(dim ? 0.22 : 0.45 + energy * 0.3),
                                                                 colors[1].opacity(0)]),
                                               center: c, startRadius: 0, endRadius: glowR))
            if f.listening {
                // Listening: a bright halo in the accent, unmistakable from across the screen.
                let haloR = diameter * (0.86 + f.mic * 0.24)
                context.fill(Path(ellipseIn: CGRect(x: c.x - haloR, y: c.y - haloR, width: haloR * 2, height: haloR * 2)),
                             with: .radialGradient(Gradient(colors: [theme.primary.opacity(0.7), theme.primary.opacity(0)]),
                                                   center: c, startRadius: r * 0.9, endRadius: haloR))
            }
            let sphere = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            context.drawLayer { layer in
                layer.clip(to: Path(ellipseIn: sphere))
                layer.fill(Path(sphere), with: .radialGradient(
                    Gradient(colors: [colors[1].blend(.black, 0.35), colors[1].blend(.black, 0.78)]),
                    center: c, startRadius: 0, endRadius: r))
                layer.blendMode = .screen
                let reach = r * (0.4 + f.mic * 0.32 - f.voice * 0.12)
                for (i, blob) in Self.blobs.enumerated() {
                    let t = f.time + blob.phase
                    let x = sin(t * blob.fx.0) + 0.5 * sin(t * blob.fx.1 + 1.7)
                    let y = cos(t * blob.fy.0) + 0.5 * cos(t * blob.fy.1 + 0.9)
                    let center = CGPoint(x: c.x + x * reach / 1.5, y: c.y + y * reach / 1.5)
                    let br = r * 0.75 * (0.85 + energy * 0.3 + 0.08 * sin(t * 1.3 + Double(i)))
                    layer.fill(Path(ellipseIn: CGRect(x: center.x - br, y: center.y - br * 0.9, width: br * 2, height: br * 1.8)),
                               with: .radialGradient(Gradient(colors: [colors[blob.color].opacity(0.75),
                                                                       colors[blob.color].opacity(0)]),
                                                     center: center, startRadius: 0, endRadius: br))
                }
                let coreR = r * 0.6 * (0.55 + f.voice * 0.75)
                layer.fill(Path(ellipseIn: CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2)),
                           with: .radialGradient(Gradient(colors: [colors[0].blend(.white, 0.7).opacity(min(f.voice * 1.1, 0.95)),
                                                                   colors[0].opacity(0)]),
                                                 center: c, startRadius: 0, endRadius: coreR))
                layer.blendMode = .normal
                let spot = CGRect(x: c.x - r * 0.76, y: c.y - r * 0.85, width: r * 0.9, height: r * 0.8)
                layer.fill(Path(ellipseIn: spot), with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.32), .white.opacity(0)]),
                    center: CGPoint(x: spot.midX, y: spot.midY), startRadius: 0, endRadius: spot.width / 2))
            }
            if f.listening {
                let pulse = 0.5 + 0.5 * sin(f.time * 2.6)
                let ringR = r * (1.14 + f.mic * 0.16)
                context.stroke(Path(ellipseIn: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2)),
                               with: .color(theme.primary.blend(.white, 0.35).opacity(0.6 + 0.35 * pulse)), lineWidth: 2.5)
            }
            if f.thinking {
                // Three dots at the lower right, like the plugin's thought bubble.
                for i in 0..<3 {
                    let lift = 2.5 * sin(f.time * 6 + Double(i) * 0.9)
                    let dot = CGRect(x: c.x + r * 0.55 + Double(i) * 6, y: c.y + r * 0.95 - lift, width: 4, height: 4)
                    context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.85)))
                }
            }
        }
        .frame(width: diameter * 1.8, height: diameter * 1.8)
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Voice Companion")
    }

    private func colors(_ look: LiveLevels.Look) -> [Color] {
        switch look {
        case .resting: [theme.primary, theme.primaryContainer, theme.tertiary]
        case .mood(let mood): mood.orbColors
        }
    }
}

// MARK: the phone

/// The device: a thin bezel, the screen with its punch-hole camera and status bar, the current screen, the assistant
/// sheet, the shade and the gesture bar.
struct PhoneBody: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var chat: ChatModel
    @ObservedObject var model: PhoneModel
    let live: LiveLevels
    let device: DeviceStatus
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        let screen = RoundedRectangle(cornerRadius: PhoneWindow.cornerRadius - PhoneWindow.bezel, style: .continuous)
        ZStack(alignment: .top) {
            theme.surface
            current
                .padding(.top, StatusBar.height)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .id(model.screen)
            if controller.showsAssistant {
                AssistantSheet(controller: controller, chat: chat, live: live)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            StatusBar(device: device, onPull: { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { model.shadeOpen = true } })
            if model.shadeOpen {
                Shade(controller: controller, chat: chat, model: model, device: device)
                    .transition(.move(edge: .top))
                    .zIndex(2)
            }
            GestureBar { controller.gestureBarTapped() }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .zIndex(3)
        }
        .clipShape(screen)
        .padding(PhoneWindow.bezel)
        .background(
            RoundedRectangle(cornerRadius: PhoneWindow.cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: PhoneWindow.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        )
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: controller.showsAssistant)
        .onExitCommand { controller.escapeInPhone() }
    }

    @ViewBuilder private var current: some View {
        switch model.screen {
        case .lock: LockScreen(controller: controller, chat: chat, model: model)
        case .home: HomeScreen(controller: controller, model: model)
        case .messages: VoiceChatScreen(controller: controller, chat: chat, recorder: controller.recorder,
                                        player: controller.player, model: model)
        case .conversations: ConversationsScreen(controller: controller, recorder: controller.recorder, model: model)
        case .conversation(let id): SavedConversationScreen(recorder: controller.recorder, player: controller.player,
                                                            model: model, id: id)
        case .settings: SettingsScreen(controller: controller, keys: controller.keys, model: model)
        case .skills: SkillsScreen(controller: controller, chat: chat, model: model)
        case .app(let id): AppScreen(controller: controller, model: model, id: id)
        }
    }
}

/// Time, the punch-hole camera, Wi-Fi and battery: the Mac's own. Click or pull it down for the shade.
struct StatusBar: View {
    static let height: CGFloat = 34
    @ObservedObject var device: DeviceStatus
    let onPull: () -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        ZStack {
            HStack(spacing: 5) {
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
                Spacer()
                Image(systemName: networkSymbol).font(.system(size: 11, weight: .semibold))
                if let battery = device.battery {
                    Text("\(battery)%").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    Image(systemName: batterySymbol(battery)).font(.system(size: 13))
                } else {
                    Image(systemName: "powerplug.fill").font(.system(size: 10))
                }
            }
            .foregroundStyle(theme.onSurface)
            .padding(.horizontal, 22)
            Circle().fill(Color.black).frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPull)
        .gesture(DragGesture(minimumDistance: 8).onEnded { if $0.translation.height > 12 { onPull() } })
    }

    private var networkSymbol: String {
        switch device.network {
        case .wifi: "wifi"
        case .wired: "cable.connector"
        case .other: "antenna.radiowaves.left.and.right"
        case .none: "wifi.slash"
        }
    }

    private func batterySymbol(_ percent: Int) -> String {
        if device.charging { return "battery.100percent.bolt" }
        return switch percent {
        case 88...: "battery.100percent"
        case 63...: "battery.75percent"
        case 38...: "battery.50percent"
        case 13...: "battery.25percent"
        default: "battery.0percent"
        }
    }
}

/// The navigation handle: back to the orb (the drawer up first, if it's down).
struct GestureBar: View {
    let action: () -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Capsule().fill(theme.onSurface.opacity(0.7)).frame(width: 104, height: 4.5)
            .padding(.vertical, 9).padding(.horizontal, 40)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .gesture(DragGesture(minimumDistance: 6).onEnded { if $0.translation.height < -8 { action() } })
            .help("Back to the orb")
    }
}

/// The wallpaper: the theme's colours with the orb's glow at the top, as if the orb lit the phone.
struct Wallpaper: View {
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.primaryContainer.opacity(0.9), theme.surfaceDim, theme.surfaceDim],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [theme.tertiary.opacity(0.35), .clear], center: .init(x: 0.85, y: 0.05),
                           startRadius: 0, endRadius: 260)
            RadialGradient(colors: [theme.primary.opacity(0.28), .clear], center: .init(x: 0.1, y: 0.25),
                           startRadius: 0, endRadius: 220)
        }
        .ignoresSafeArea()
    }
}

// MARK: lock screen

/// Where a conversation started by voice opens: the clock, how to talk, and what came in lately.
struct LockScreen: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var chat: ChatModel
    @ObservedObject var model: PhoneModel
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        ZStack {
            Wallpaper().padding(.top, -StatusBar.height)
            VStack(spacing: 0) {
                TimelineView(.everyMinute) { context in
                    VStack(spacing: 4) {
                        Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                            .font(.system(size: 78, weight: .light)).monospacedDigit()
                        Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(.system(size: 15, weight: .medium))
                    }
                }
                .foregroundStyle(theme.onSurface)
                .padding(.top, 30)
                Chip(symbol: controller.stateSymbol, text: "\(controller.name) · \(chat.controls.state)")
                    .padding(.top, 14)
                VStack(spacing: 8) {
                    ForEach(chat.notifications.prefix(2)) { NotificationCard(line: $0, compact: true) }
                }
                .padding(.horizontal, 14).padding(.top, 22)
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: controller.talkSymbol).font(.system(size: 13, weight: .semibold))
                    Text(controller.talkHint).font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(theme.surfaceContainerHigh.opacity(0.85)))
                Image(systemName: "lock.open.fill").font(.system(size: 15)).foregroundStyle(theme.onSurfaceVariant)
                    .padding(.top, 16).padding(.bottom, 34)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.go(.home) }
    }
}

struct Chip: View {
    let symbol: String
    let text: String
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(theme.onSecondaryContainer)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(theme.secondaryContainer))
    }
}

// MARK: home screen

/// Her skills as apps: each harness she can control, each skill she learned, and empty "Teach me" slots while she
/// knows little; Messages, Skills and Settings in the dock; a search pill that talks or types.
struct HomeScreen: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var model: PhoneModel
    @Environment(\.phoneTheme) private var theme

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        ZStack {
            Wallpaper().padding(.top, -StatusBar.height)
            VStack(alignment: .leading, spacing: 0) {
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.date, format: .dateTime.weekday(.wide).day().month(.abbreviated))
                            .font(.system(size: 20, weight: .regular))
                        Text("\(controller.name) · \(controller.chat.controls.state)")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.onSurfaceVariant)
                    }
                }
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 22).padding(.top, 18)
                Chip(symbol: controller.talkSymbol, text: controller.talkHint)
                    .padding(.horizontal, 20).padding(.top, 12)
                Spacer(minLength: 12)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(controller.homeApps) { app in
                        AppIcon(app: app) { controller.openApp(app) }
                    }
                }
                .padding(.horizontal, 12)
                Spacer(minLength: 12)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(controller.dockApps) { app in
                        AppIcon(app: app, showsLabel: false) { controller.openApp(app) }
                    }
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(theme.surfaceContainer.opacity(0.7)))
                .padding(.horizontal, 10)
                SearchPill(controller: controller, model: model)
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 30)
            }
        }
    }
}

/// An app on the home screen: a harness, a learned skill, an empty slot to teach her one, or one of her own.
struct PhoneApp: Identifiable, Hashable {
    enum Kind: Hashable { case harness, skill, teach, messages, skills, settings, talk }
    let id: String
    let kind: Kind
    let title: String
    let symbol: String
    /// Off or unavailable: drawn faded.
    var dimmed = false
}

struct AppIcon: View {
    let app: PhoneApp
    var showsLabel = true
    let action: () -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if app.kind == .teach {
                        Circle().strokeBorder(theme.onSurfaceVariant.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    } else {
                        Circle().fill(fill)
                    }
                    Image(systemName: app.symbol)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(app.kind == .teach ? theme.onSurfaceVariant : foreground)
                }
                .frame(width: 52, height: 52)
                .opacity(app.dimmed ? 0.45 : 1)
                if showsLabel {
                    Text(app.title).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.onSurface)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: 66)
                }
            }
        }
        .buttonStyle(.plain)
        .help(app.title)
    }

    private var fill: Color {
        switch app.kind {
        case .harness: theme.primaryContainer
        case .skill: theme.tertiaryContainer
        case .messages, .talk: theme.primary
        case .skills, .settings: theme.secondaryContainer
        case .teach: .clear
        }
    }

    private var foreground: Color {
        switch app.kind {
        case .harness: theme.onPrimaryContainer
        case .skill: theme.onTertiaryContainer
        case .messages, .talk: theme.onPrimary
        case .skills, .settings: theme.onSecondaryContainer
        case .teach: theme.onSurfaceVariant
        }
    }
}

/// The Pixel's search pill, for her: the mic starts a conversation, the keyboard opens Messages.
struct SearchPill: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var model: PhoneModel
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.primary)
            Text("Ask \(controller.name)").font(.system(size: 14, weight: .medium)).foregroundStyle(theme.onSurfaceVariant)
            Spacer()
            Button { model.go(.messages) } label: { Image(systemName: "keyboard").font(.system(size: 15)) }
                .buttonStyle(.plain).foregroundStyle(theme.onSurface).help("Type to her")
            Button { controller.talkTapped() } label: { Image(systemName: "mic.fill").font(.system(size: 15)) }
                .buttonStyle(.plain).foregroundStyle(theme.primary).help("Talk")
        }
        .padding(.horizontal, 18).frame(height: 46)
        .background(Capsule().fill(theme.surfaceContainerHigh))
        .contentShape(Capsule())
        .onTapGesture { model.go(.messages) }
    }
}

// MARK: the assistant sheet

/// Rises from the bottom during a conversation: the light bar, what you said and what she says, and where the turn
/// stands (listening, about to send, thinking, speaking, the follow-up countdown).
struct AssistantSheet: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var chat: ChatModel
    let live: LiveLevels
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Color.black.opacity(0.35).contentShape(Rectangle())
                .onTapGesture { controller.dismissConversation() }
            VStack(spacing: 14) {
                Capsule().fill(theme.onSurfaceVariant.opacity(0.4)).frame(width: 32, height: 4).padding(.top, 10)
                LightBar(live: live, phase: controller.conversation, muted: chat.controls.muted)
                    .frame(height: 44)
                VStack(alignment: .leading, spacing: 8) {
                    if let you = lastLine(.you) {
                        Text(you).font(.system(size: 14)).foregroundStyle(theme.onSurfaceVariant).lineLimit(2)
                    }
                    Text(lastLine(.voice) ?? controller.conversationPrompt)
                        .font(.system(size: 18, weight: .regular)).foregroundStyle(theme.onSurface)
                        .lineLimit(5).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .animation(.easeOut(duration: 0.2), value: chat.lines.count)
                HStack(spacing: 10) {
                    Chip(symbol: controller.handsFree ? "infinity" : "waveform", text: controller.conversationStatus)
                        .fixedSize()
                    Spacer(minLength: 4)
                    RoundIcon(symbol: chat.controls.muted ? "mic.slash.fill" : "mic.fill", tinted: !chat.controls.muted,
                              help: chat.controls.muteTitle) { controller.press(chat.controls.mutePress) }
                        .overlay(FollowUpRing(live: live).allowsHitTesting(false))
                    RoundIcon(symbol: "keyboard", tinted: false, help: "Type instead") { controller.phone.go(.messages) }
                    RoundIcon(symbol: "xmark", tinted: false, help: "End the conversation (Esc)") {
                        controller.dismissConversation()
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 30)
            }
            .background(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(theme.surfaceContainerHigh))
        }
    }

    private func lastLine(_ kind: ChatModel.Line.Kind) -> String? {
        chat.lines.last { $0.kind == kind && $0.time > controller.conversationStarted }?.text
    }
}

struct RoundIcon: View {
    let symbol: String
    let tinted: Bool
    let help: String
    let action: () -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tinted ? theme.onPrimary : theme.onSurface)
                .frame(width: 44, height: 44)
                .background(Circle().fill(tinted ? theme.primary : theme.surfaceContainerHighest))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The follow-up window's countdown, around the mic button.
struct FollowUpRing: View {
    @ObservedObject var live: LiveLevels
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        if let left = live.frame.followUp {
            Circle().trim(from: 0, to: left).rotation(.degrees(-90))
                .stroke(theme.tertiary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 52, height: 52)
        }
    }
}

/// Google's four colours, alive: they bounce with your voice while listening, wave with hers while she speaks,
/// take turns while she thinks, close in and fill a ring during the cooldown, and rest grey while muted.
struct LightBar: View {
    @ObservedObject var live: LiveLevels
    let phase: TurnTaking.Phase
    let muted: Bool

    var body: some View {
        let f = live.frame
        ZStack {
            if let progress = f.cooldown {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 3).frame(width: 40, height: 40)
                Circle().trim(from: 0, to: progress).rotation(.degrees(-90))
                    .stroke(AngularGradient(colors: PhoneTheme.assistantColors + [PhoneTheme.assistantColors[0]],
                                            center: .center), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 40, height: 40)
            }
            HStack(spacing: spacing(f)) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(muted ? Color.gray.opacity(0.7) : PhoneTheme.assistantColors[i])
                        .frame(width: dot(f), height: height(i, f))
                        .offset(y: lift(i, f))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Light bar")
    }

    private func dot(_ f: LiveLevels.Frame) -> CGFloat { f.cooldown != nil ? 7 : 11 }

    private func spacing(_ f: LiveLevels.Frame) -> CGFloat {
        if let progress = f.cooldown { return 9 - 6 * progress } // closing in: about to send
        return 9
    }

    private func height(_ i: Int, _ f: LiveLevels.Frame) -> CGFloat {
        let base = dot(f)
        guard !muted, f.cooldown == nil else { return base }
        let wave = (sin(f.time * 7 + Double(i) * 1.3) + 1) / 2
        if case .listening = phase { return base + CGFloat(f.mic * (6 + 30 * wave)) }
        if f.voice > 0.02 { return base + CGFloat(f.voice * (6 + 28 * wave)) }
        return base
    }

    private func lift(_ i: Int, _ f: LiveLevels.Frame) -> CGFloat {
        guard !muted, f.cooldown == nil else { return 0 }
        if f.thinking && f.voice < 0.02 { return CGFloat(-7 * max(0, sin(f.time * 5 - Double(i) * 0.8))) }
        return 0
    }
}

// MARK: shade

/// Pulled down from the status bar: quick settings for the session, then what came in (agent reports, tool
/// results, her changes and questions), newest first.
struct Shade: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var chat: ChatModel
    @ObservedObject var model: PhoneModel
    @ObservedObject var device: DeviceStatus
    @Environment(\.phoneTheme) private var theme

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.everyMinute) { context in
                HStack(alignment: .firstTextBaseline) {
                    Text(context.date, format: .dateTime.hour().minute()).font(.system(size: 30, weight: .regular))
                    Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.onSurfaceVariant)
                    Spacer()
                    Button { model.go(.settings) } label: { Image(systemName: "gearshape").font(.system(size: 15)) }
                        .buttonStyle(.plain).help("Settings")
                }
                .foregroundStyle(theme.onSurface)
            }
            .padding(.top, 36)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(controller.quickTiles) { tile in QuickTile(tile: tile) }
            }
            if !chat.status.isEmpty {
                Text(chat.status).font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant).lineLimit(1)
            }
            HStack {
                Text("Notifications").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.onSurfaceVariant)
                Spacer()
            }
            .padding(.top, 2)
            PhoneScroll {
                VStack(spacing: 8) {
                    if chat.notifications.isEmpty {
                        Text("Nothing yet. Agent reports, results and her questions show up here.")
                            .font(.system(size: 13)).foregroundStyle(theme.onSurfaceVariant)
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                    }
                    ForEach(chat.notifications) { NotificationCard(line: $0, compact: false) }
                }
            }
            Capsule().fill(theme.onSurfaceVariant.opacity(0.5)).frame(width: 36, height: 4)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { model.shadeOpen = false } }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.surfaceContainer)
        .gesture(DragGesture(minimumDistance: 8).onEnded {
            if $0.translation.height < -12 { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { model.shadeOpen = false } }
        })
    }
}

/// A quick-settings tile: tinted while it holds something (muted, paused, disconnected) or is on.
struct QuickTileModel: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let on: Bool
    let enabled: Bool
    let action: () -> Void
}

struct QuickTile: View {
    let tile: QuickTileModel
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Button(action: tile.action) {
            HStack(spacing: 10) {
                Image(systemName: tile.symbol).font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tile.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(tile.subtitle).font(.system(size: 11)).lineLimit(1).opacity(0.8)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(tile.on ? theme.onPrimaryContainer : theme.onSurface)
            .padding(.horizontal, 12).frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tile.on ? theme.primaryContainer : theme.surfaceContainerHighest))
            .opacity(tile.enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!tile.enabled)
    }
}

struct NotificationCard: View {
    let line: ChatModel.Line
    let compact: Bool
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint).frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.onSurface)
                    Spacer()
                    Text(line.time, format: .dateTime.hour().minute()).font(.system(size: 10))
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                Text(body(line.text)).font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(compact ? 2 : 4)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.surfaceContainerHigh.opacity(compact ? 0.88 : 1)))
    }

    private var title: String {
        switch line.kind {
        case .result: String(line.text.prefix { $0 != ":" })
        case .change: "She changed"
        case .ask: "Waiting for your yes"
        default: line.text.hasPrefix("←") ? "Report" : line.text.hasPrefix("✖") || line.text.hasPrefix("⚠") ? "Problem" : "Note"
        }
    }

    private func body(_ text: String) -> String {
        switch line.kind {
        case .result: String(text.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces)
        case .ask: text.replacingOccurrences(of: "Waiting for your yes: ", with: "")
        default: text
        }
    }

    private var symbol: String {
        switch line.kind {
        case .result: "checkmark"
        case .change: "sparkles"
        case .ask: "questionmark"
        default: line.text.hasPrefix("✖") || line.text.hasPrefix("⚠") ? "exclamationmark" : "bell.fill"
        }
    }

    private var tint: Color {
        switch line.kind {
        case .change: theme.success
        case .ask: theme.tertiary
        default: line.text.hasPrefix("✖") || line.text.hasPrefix("⚠") ? theme.error : theme.primary
        }
    }
}

/// A scroll view, or (rendering to an image) its content as is, which an image renderer can draw.
struct PhoneScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.phoneSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            // Top-aligned in a fixed frame: what overflows is cut at the bottom, as a scroll view at rest shows it.
            GeometryReader { geometry in
                content.frame(width: geometry.size.width).fixedSize(horizontal: false, vertical: true)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    .clipped()
            }
        } else {
            ScrollView(showsIndicators: false) { content }
        }
    }
}
