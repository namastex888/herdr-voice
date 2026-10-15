import AppKit
import HerdrVoiceCore
import SwiftUI

// The phone's apps: Messages (the conversation, typed or spoken), Skills (what she controls, knows and changed),
// Settings (who she is, how she listens and sounds, keys) and one app per harness or learned skill. Every edit goes
// through the controller as the human's own change, logged and revertible, as the 0.2 panels did.

// MARK: building blocks

/// An app's top bar: back to home, the title, and an optional trailing control.
struct TopBar<Trailing: View>: View {
    let title: String
    let back: () -> Void
    @ViewBuilder var trailing: Trailing
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Image(systemName: "arrow.left").font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36).contentShape(Circle())
            }
            .buttonStyle(.plain).help("Home")
            Text(title).font(.system(size: 20, weight: .regular)).lineLimit(1)
            Spacer()
            trailing
        }
        .foregroundStyle(theme.onSurface)
        .padding(.horizontal, 10).frame(height: 50)
    }
}

extension TopBar where Trailing == EmptyView {
    init(title: String, back: @escaping () -> Void) {
        self.init(title: title, back: back) { EmptyView() }
    }
}

/// A Material card: a titled group of rows on a raised surface.
struct Card<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: Content
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primary)
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(theme.surfaceContainer))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
            }
        }
    }
}

/// Material's switch: a track with a thumb that grows and shows a check when on.
struct MSwitch: View {
    let isOn: Bool
    let set: (Bool) -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Button { set(!isOn) } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? theme.primary : theme.surfaceContainerHighest)
                    .overlay(Capsule().strokeBorder(isOn ? .clear : theme.outline, lineWidth: 1.5))
                Circle().fill(isOn ? theme.onPrimary : theme.outline)
                    .frame(width: isOn ? 22 : 15, height: isOn ? 22 : 15)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.primary).opacity(isOn ? 1 : 0))
                    .padding(.horizontal, isOn ? 4 : 7)
            }
            .frame(width: 48, height: 28)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

/// A row with a title, an optional detail and a switch.
struct SwitchRow: View {
    let title: String
    var detail: String?
    let isOn: Bool
    let set: (Bool) -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundStyle(theme.onSurface)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            MSwitch(isOn: isOn, set: set)
        }
    }
}

/// A radio choice: one of a few options, each with a line saying what it means.
struct OptionRow: View {
    let title: String
    var detail: String?
    let selected: Bool
    var badge: String?
    let choose: () -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().strokeBorder(selected ? theme.primary : theme.outline, lineWidth: 2).frame(width: 18, height: 18)
                    if selected { Circle().fill(theme.primary).frame(width: 9, height: 9) }
                }
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                        if let badge {
                            Text(badge).font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(theme.tertiaryContainer))
                                .foregroundStyle(theme.onTertiaryContainer)
                        }
                    }
                    .foregroundStyle(theme.onSurface)
                    if let detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A text field that edits a draft and saves on Return or Save, so typing doesn't log a change per keystroke (and
/// renew her instructions). It follows the saved value when that changes elsewhere (her proposals, a revert).
struct PhoneField: View {
    let title: String
    let value: String
    var placeholder = ""
    var lines = 1
    var secure = false
    let save: (String) -> Void
    @State private var draft: String
    @Environment(\.phoneTheme) private var theme
    @Environment(\.phoneSnapshot) private var snapshot

    init(_ title: String, value: String, placeholder: String = "", lines: Int = 1, secure: Bool = false,
         save: @escaping (String) -> Void) {
        self.title = title
        self.value = value
        self.placeholder = placeholder
        self.lines = lines
        self.secure = secure
        self.save = save
        _draft = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.onSurfaceVariant)
            HStack(alignment: .top, spacing: 8) {
                field
                    .font(.system(size: 14)).foregroundStyle(theme.onSurface)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surfaceContainerHighest))
                if draft != value {
                    Button("Save") { save(draft) }.buttonStyle(TonalButton(prominent: true))
                }
            }
        }
        .onChange(of: value) { _, saved in draft = saved }
    }

    @ViewBuilder private var field: some View {
        let hint = placeholder.isEmpty ? title : placeholder
        if snapshot {
            Text(secure ? (value.isEmpty ? hint : "••••••••") : (value.isEmpty ? hint : value))
                .opacity(value.isEmpty ? 0.5 : 1).lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if secure {
            SecureField(hint, text: $draft).textFieldStyle(.plain).onSubmit { save(draft) }
        } else {
            TextField(hint, text: $draft, axis: .vertical).textFieldStyle(.plain)
                .lineLimit(1...max(lines, 1)).onSubmit { save(draft) }
        }
    }
}

/// Material's filled-tonal and filled buttons.
struct TonalButton: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.phoneTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(destructive ? Color.black.opacity(0.85) : prominent ? theme.onPrimary : theme.onSecondaryContainer)
            .background(Capsule().fill(destructive ? theme.error : prominent ? theme.primary : theme.secondaryContainer))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// What came of the human's last edit.
struct NoticeBanner: View {
    let text: String
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        if !text.isEmpty {
            Text(text).font(.system(size: 12)).foregroundStyle(theme.onTertiaryContainer)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(theme.tertiaryContainer))
        }
    }
}

// MARK: Messages (the voice chat's other lines)

/// A line of the conversation that isn't a voice note: what she ran, its result, her question, a change, a note.
struct MessageCard: View {
    let line: ChatModel.Line
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        switch line.kind {
        case .you:
            HStack {
                Spacer(minLength: 40)
                bubble(theme.primaryContainer, theme.onPrimaryContainer,
                       corners: (20, 20, 6, 20))
            }
        case .voice:
            HStack {
                bubble(theme.surfaceContainerHigh, theme.onSurface, corners: (20, 20, 20, 6))
                Spacer(minLength: 40)
            }
        case .tool:
            Label(line.text, systemImage: "bolt.fill").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.onSurfaceVariant).lineLimit(2)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(theme.surfaceContainerLow))
        case .result:
            Label(line.text, systemImage: "checkmark.circle.fill").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.85)).lineLimit(3)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(theme.surfaceContainerLow))
        case .ask:
            VStack(alignment: .leading, spacing: 4) {
                Label("Waiting for your yes", systemImage: "questionmark.circle.fill").font(.system(size: 12, weight: .semibold))
                Text(line.text.replacingOccurrences(of: "Waiting for your yes: ", with: "")).font(.system(size: 13))
                Text("Say or type yes to go ahead.").font(.system(size: 11)).opacity(0.8)
            }
            .foregroundStyle(theme.onTertiaryContainer)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(theme.tertiaryContainer))
        case .change:
            Label(line.text, systemImage: "sparkles").font(.system(size: 12))
                .foregroundStyle(theme.success)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(theme.success.opacity(0.12)))
        case .note:
            Text(line.text).font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
        }
    }

    private func bubble(_ fill: Color, _ text: Color, corners: (CGFloat, CGFloat, CGFloat, CGFloat)) -> some View {
        Text(line.text).font(.system(size: 14)).foregroundStyle(text).textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(UnevenRoundedRectangle(topLeadingRadius: corners.0, bottomLeadingRadius: corners.3,
                                               bottomTrailingRadius: corners.2, topTrailingRadius: corners.1,
                                               style: .continuous).fill(fill))
    }
}

// MARK: Settings

/// Who she is, how she listens and sounds, routing, keys and the look; every field saves as your own change.
struct SettingsScreen: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var keys: CompanionKeys
    @ObservedObject var model: PhoneModel
    @State private var factDraft = ""
    @State private var confirmReset = false
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Settings", back: { model.go(.home) })
            PhoneScroll {
                VStack(alignment: .leading, spacing: 16) {
                    NoticeBanner(text: controller.notice)
                    profile
                    listening
                    identity
                    memory
                    voice
                    keysCard
                    routing
                    look
                    reset
                }
                .padding(.horizontal, 12).padding(.bottom, 40)
            }
        }
        .background(theme.surface)
    }

    private var profile: some View {
        HStack(spacing: 12) {
            Text(String(controller.name.prefix(1))).font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.onPrimary).frame(width: 48, height: 48).background(Circle().fill(theme.primary))
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.onSurface)
                Text("\(controller.provider.menuTitle) · \(controller.voice) · \(controller.settings.activation.title)")
                    .font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(theme.surfaceContainerHigh))
    }

    private var listening: some View {
        let s = controller.settings
        return Card(title: "Listening", footer: "Only your own settings change this; she can't propose it.") {
            ForEach(ActivationMode.allCases, id: \.self) { mode in
                OptionRow(title: mode.title, detail: mode.detail, selected: s.activation == mode,
                          badge: mode == .alwaysOn ? "costly" : mode == .tapToTalk ? "default" : nil) {
                    controller.setActivation(mode)
                }
            }
            if s.activation.opensOnRequest {
                Divider().overlay(theme.outlineVariant)
                Text("Key").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.onSurfaceVariant)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(ActivationKey.allCases, id: \.self) { key in
                        Button { controller.setActivationKey(key) } label: {
                            Text(key.title).lineLimit(1).fixedSize().frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TonalButton(prominent: s.activationKey == key))
                    }
                }
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Follow-up").font(.system(size: 14)).foregroundStyle(theme.onSurface)
                        Text("After her reply, talk without the key").font(.system(size: 11))
                            .foregroundStyle(theme.onSurfaceVariant).fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Button { controller.setFollowUp(s.followUpSeconds - 1) } label: { Image(systemName: "minus") }
                            .buttonStyle(TonalButton())
                        Text("\(Int(s.followUpSeconds)) s").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(theme.onSurface).frame(width: 34)
                        Button { controller.setFollowUp(s.followUpSeconds + 1) } label: { Image(systemName: "plus") }
                            .buttonStyle(TonalButton())
                    }
                    .fixedSize()
                }
            }
            if s.activation == .wakeWord {
                PhoneField("Wake phrase", value: s.wakePhrase) { controller.setWakePhrase($0) }
            }
            if !controller.activationNote.isEmpty {
                Text(controller.activationNote).font(.system(size: 11)).foregroundStyle(theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow Input Monitoring") { controller.requestKeyPermission() }.buttonStyle(TonalButton(prominent: true))
            }
        }
    }

    private var identity: some View {
        Card(title: "Identity", footer: "She can propose changes to these too; hers apply only after your yes.") {
            PhoneField("Name", value: controller.identity("name")) { controller.setIdentity("name", $0) }
            PhoneField("Role", value: controller.identity("role")) { controller.setIdentity("role", $0) }
            PhoneField("Personality", value: controller.identity("personality"), lines: 3) {
                controller.setIdentity("personality", $0)
            }
            PhoneField("Learned instructions", value: controller.identity("instructions"),
                       placeholder: "How you like things done. She proposes these as she learns.", lines: 5) {
                controller.setIdentity("instructions", $0)
            }
        }
    }

    private var memory: some View {
        Card(title: "Memory") {
            if controller.facts.isEmpty {
                Text("Nothing yet. She proposes facts worth keeping (“remember standup is at 10”) and asks first.")
                    .font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
            }
            ForEach(controller.facts, id: \.self) { fact in
                HStack(alignment: .top) {
                    Text(fact).font(.system(size: 13)).foregroundStyle(theme.onSurface).textSelection(.enabled)
                    Spacer()
                    Button { controller.removeFact(fact) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(theme.onSurfaceVariant).help("Forget this")
                }
            }
            PhoneField("Add a fact", value: "", placeholder: "Standup is at 10:00") { controller.addFact($0) }
        }
    }

    private var voice: some View {
        Card(title: "Voice") {
            ForEach(CompanionKeys.providers, id: \.self) { provider in
                OptionRow(title: provider.menuTitle, detail: keys.hasKey(provider) ? provider.model : "No key yet",
                          selected: controller.provider == provider) { controller.chooseProvider(provider) }
            }
            PhoneField("Voice", value: controller.settings.voice ?? "",
                       placeholder: "\(controller.provider.defaultVoice) (the model's default)") { controller.setVoiceName($0) }
        }
    }

    private var keysCard: some View {
        Card(title: "API keys", footer: "Stored in your Keychain, never in her configuration.") {
            ForEach(CompanionKeys.providers, id: \.self) { provider in
                PhoneField("\(provider.menuTitle) key\(keys.hasKey(provider) ? " (saved)" : "")", value: "",
                           placeholder: keys.hasKey(provider) ? "Saved; paste to replace" : "Paste a key", secure: true) {
                    controller.saveKey($0, for: provider)
                }
            }
        }
    }

    private var routing: some View {
        Card(title: "Skill routing") {
            SwitchRow(title: "Route each turn with Jev",
                      detail: controller.settings.routeWithJev && keys.hasJevKey
                          ? "Routing with \(controller.settings.jevModel)." : "Routing by words until Jev is on and has a key.",
                      isOn: controller.settings.routeWithJev) { controller.setRouteWithJev($0) }
            PhoneField("Jev (TypeSafe) key\(keys.hasJevKey ? " (saved)" : "")", value: "",
                       placeholder: "Paste a key", secure: true) { controller.saveJevKey($0) }
            Button("Use MeetingPulse's Jev key") { controller.importJevKey() }.buttonStyle(TonalButton())
            PhoneField("Jev model", value: controller.settings.jevModel) { controller.setJevModel($0) }
        }
    }

    private var look: some View {
        Card(title: "Look") {
            HStack(spacing: 10) {
                ForEach(PhoneTheme.Seed.allCases) { seed in
                    let swatch = PhoneTheme(seed: seed)
                    Button { controller.setAccent(seed) } label: {
                        Circle().fill(swatch.primary).frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(theme.onSurface, lineWidth: model.theme.seed == seed ? 2.5 : 0))
                    }
                    .buttonStyle(.plain).help(seed.rawValue.capitalized)
                }
            }
        }
    }

    private var reset: some View {
        Card(footer: "Reset forgets every skill, fact and learned instruction and restores her factory identity and "
             + "settings. Your harness switches, voice model, how she listens and keys stay.") {
            HStack {
                Button(confirmReset ? "Tap again to reset" : "Reset to new hire") {
                    if confirmReset { controller.resetToNewHire() }
                    confirmReset.toggle()
                }
                .buttonStyle(TonalButton(destructive: true))
                Spacer()
                Button("Configuration folder") { controller.openConfigFolder() }.buttonStyle(TonalButton())
            }
        }
    }
}

// MARK: Skills

/// The map of what she can do: what she controls (yours to switch), what she knows, how she changed and grew.
struct SkillsScreen: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var chat: ChatModel
    @ObservedObject var model: PhoneModel
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Skills", back: { model.go(.home) })
            PhoneScroll {
                VStack(alignment: .leading, spacing: 16) {
                    NoticeBanner(text: controller.notice)
                    Card(title: "What I can control") {
                        ForEach(controller.harnesses) { harness in
                            HarnessRow(controller: controller, harness: harness,
                                       loaded: chat.activeSkills.contains(harness.id), model: model)
                        }
                    }
                    Card(title: "What I know") {
                        if controller.skills.isEmpty {
                            Text("I'm new here, so I don't know any skills yet. Teach me by voice or in Messages: “when I "
                                 + "say start my day, open Mail and Calendar and set the volume to 30”. I'll say what I'd "
                                 + "save and wait for your yes.")
                                .font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                        }
                        ForEach(controller.skills) { info in
                            Button { model.go(.app(info.id)) } label: {
                                HStack {
                                    Image(systemName: "sparkles").foregroundStyle(theme.tertiary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(info.skill.title).font(.system(size: 14, weight: .medium))
                                        Text(info.skill.summary).font(.system(size: 11)).lineLimit(1)
                                            .foregroundStyle(theme.onSurfaceVariant)
                                    }
                                    Spacer()
                                    StatusDot(status: info.status)
                                }
                                .foregroundStyle(theme.onSurface).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Card(title: "How I've changed") {
                        if controller.changes.isEmpty {
                            Text("No changes yet. Each one, mine (after your yes) or yours, shows here and can be reverted.")
                                .font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                        }
                        ForEach(controller.changes.prefix(20)) { ChangeRow(controller: controller, change: $0) }
                    }
                    Card(title: "Growth") {
                        GrowthGrid(metrics: controller.metrics, skills: controller.skills.count, facts: controller.facts.count)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 40)
            }
        }
        .background(theme.surface)
        .onAppear { controller.refresh() }
    }
}

struct StatusDot: View {
    let status: EntryStatus
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).help(text)
    }

    private var color: Color {
        switch status {
        case .active: theme.success
        case .disabled, .inactive: theme.outline
        case .failed: theme.error
        }
    }

    private var text: String {
        switch status {
        case .active: "Active"
        case .disabled: "Off"
        case .inactive(let reason): "Inactive: \(reason)"
        case .failed(let error): "Failed: \(error)"
        }
    }
}

private struct HarnessRow: View {
    @ObservedObject var controller: CompanionController
    let harness: CompanionController.HarnessInfo
    let loaded: Bool
    @ObservedObject var model: PhoneModel
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SwitchRow(title: harness.title,
                      detail: (harness.status == .active ? (loaded ? "On · loaded" : "On") : harness.statusText)
                          + " · \(harness.actions.count) actions",
                      isOn: harness.on) { controller.setHarness(harness.id, on: $0) }
            Button("See its controls") { model.go(.app(harness.id)) }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.primary)
        }
    }
}

private struct ChangeRow: View {
    @ObservedObject var controller: CompanionController
    let change: ChangeRecord
    @Environment(\.phoneTheme) private var theme

    private var undoneBy: String? { controller.changes.first { $0.revertOf == change.id }?.id }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(change.summary).font(.system(size: 13)).foregroundStyle(theme.onSurface)
                Text("\(change.by == .user ? "You" : controller.name) · \(change.time.formatted(.relative(presentation: .named)))"
                     + (undoneBy.map { " · undone by \($0)" } ?? ""))
                    .font(.system(size: 10)).foregroundStyle(theme.onSurfaceVariant)
            }
            Spacer()
            Button("Revert") { controller.revert(change.id) }.buttonStyle(TonalButton()).disabled(undoneBy != nil)
                .opacity(undoneBy == nil ? 1 : 0.4)
        }
    }
}

private struct GrowthGrid: View {
    let metrics: GrowthMetrics
    let skills: Int
    let facts: Int
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        let rows: [(String, Int)] = [
            ("Skills I know", skills), ("Facts I remember", facts), ("Skills you taught me", metrics.skillsTaught),
            ("Skill runs", metrics.replays), ("Runs that stopped partway", metrics.replayFailures),
            ("Changes you said yes to", metrics.proposalsApplied), ("Changes reverted", metrics.reverted),
        ]
        VStack(spacing: 6) {
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0).foregroundStyle(theme.onSurfaceVariant)
                    Spacer()
                    Text("\(row.1)").monospacedDigit().foregroundStyle(theme.onSurface)
                }
                .font(.system(size: 13))
            }
        }
    }
}

// MARK: an app per harness or skill

/// A harness's app (its switch and every control) or a learned skill's (what it does, its steps and notes).
struct AppScreen: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var model: PhoneModel
    let id: String
    @State private var confirmForget = false
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: title, back: { model.go(.home) })
            PhoneScroll {
                VStack(alignment: .leading, spacing: 16) {
                    NoticeBanner(text: controller.notice)
                    if let harness = controller.harnesses.first(where: { $0.id == id }) {
                        harnessContent(harness)
                    } else if let info = controller.skills.first(where: { $0.id == id }) {
                        skillContent(info)
                    } else {
                        Text("This app is gone: she forgot the skill, or the harness went away.")
                            .font(.system(size: 13)).foregroundStyle(theme.onSurfaceVariant)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 40)
            }
        }
        .background(theme.surface)
    }

    private var title: String { controller.title(ofSkill: id) }

    @ViewBuilder private func harnessContent(_ harness: CompanionController.HarnessInfo) -> some View {
        Card {
            SwitchRow(title: harness.title, detail: harness.statusText, isOn: harness.on) {
                controller.setHarness(harness.id, on: $0)
            }
            if harness.name == "mac" {
                SwitchRow(title: "AppleScript", detail: "Each script needs your spoken yes.",
                          isOn: controller.appleScriptOn) { controller.setAppleScript($0) }
            }
            if harness.name == "shell" {
                Text("Each command needs your spoken yes.").font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant)
            }
        }
        Card(title: "\(harness.actions.count) controls") {
            ForEach(harness.actions, id: \.self) { action in
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.onSurface)
                    Text(action.description).font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func skillContent(_ info: CompanionController.SkillInfo) -> some View {
        let skill = info.skill
        Card {
            HStack {
                StatusDot(status: info.status)
                Text(skill.summary.isEmpty ? skill.title : skill.summary).font(.system(size: 14))
                    .foregroundStyle(theme.onSurface)
            }
            if !skill.needs.isEmpty {
                Text("Needs " + skill.needs.map { need in controller.harnesses.first { $0.name == need }?.title ?? need }
                    .joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant)
            }
            Button(confirmForget ? "Tap again to forget" : "Forget") {
                if confirmForget { controller.forgetSkill(skill.id) }
                confirmForget.toggle()
            }
            .buttonStyle(TonalButton(destructive: true))
        }
        if !skill.steps.isEmpty {
            Card(title: "Steps") {
                ForEach(Array(skill.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step.action)\(step.arguments == "{}" ? "" : " \(step.arguments)")")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.onSurfaceVariant)
                        .textSelection(.enabled)
                }
            }
        }
        if !skill.playbook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Card(title: "How-to notes") {
                Text(skill.playbook).font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant).textSelection(.enabled)
            }
        }
    }
}
