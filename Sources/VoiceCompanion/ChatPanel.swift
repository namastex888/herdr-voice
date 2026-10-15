import AppKit
import HerdrVoiceCore
import SwiftUI

/// A floating panel that can take typing. An accessory app's non-activating panel never becomes key, so this one is
/// a plain panel that may, and the app activates itself when the panel is shown.
final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class ChatWindow {
    let panel: ChatPanel

    init(content: some View) {
        panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                          backing: .buffered, defer: false)
        panel.title = "Voice Companion"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 340, height: 420)
        panel.contentView = NSHostingView(rootView: content)
        if !panel.setFrameUsingName("VoiceCompanionChat"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 420, y: screen.minY + 24))
        }
        panel.setFrameAutosaveName("VoiceCompanionChat")
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if panel.isVisible { panel.orderOut(nil) } else { show() }
    }
}

enum CompanionTab: String, CaseIterable, Identifiable {
    case chat = "Chat", skills = "Skills", settings = "Settings"
    var id: String { rawValue }
}

struct CompanionView: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var chat: ChatModel
    @ObservedObject var settings: CompanionSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch controller.tab {
            case .chat: ChatView(controller: controller, chat: chat)
            case .skills: SkillsView(controller: controller, chat: chat)
            case .settings: SettingsView(controller: controller, settings: settings)
            }
        }
        .frame(minWidth: 340, minHeight: 420)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(chat.connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                .help(chat.connected ? "Connected" : "Not connected; it opens when you speak or type")
            Text(chat.provider.menuTitle).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $controller.tab) {
                ForEach(CompanionTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 210)
            Button { controller.toggleMute() } label: {
                Image(systemName: chat.muted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(chat.muted ? Color.red : Color.primary)
            }
            .buttonStyle(.borderless).help(chat.muted ? "Unmute (⌥⌘M)" : "Mute (⌥⌘M)")
        }
        .padding(.horizontal, 14).padding(.top, 30).padding(.bottom, 10)
    }
}

// MARK: chat

private struct ChatView: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var chat: ChatModel
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            skillStrip
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if chat.lines.isEmpty {
                            Text("Talk any time, or type below. Try “open Safari”, “set the volume to 30”, or “learn a skill called "
                                 + "start my day that opens Mail and Calendar”.")
                                .font(.callout).foregroundStyle(.secondary).padding(.top, 24)
                        }
                        ForEach(chat.lines) { LineView(line: $0).id($0.id) }
                    }
                    .padding(14)
                }
                .onChange(of: chat.lines.last?.id) { _, last in
                    if let last { withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(last, anchor: .bottom) } }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Type to Voice Companion…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4).focused($typing).onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
        }
        .onAppear { typing = true }
    }

    private var skillStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chat.activeSkills, id: \.self) { id in
                    Text(controller.title(ofSkill: id)).font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(id == chat.activeSkills.first ? 0.25 : 0.1)))
                }
                if let route = chat.lastRoute {
                    Text(route.skill == RouteDecision.chat ? "just talking" : "\(route.source == .jev ? "Jev" : "words") "
                         + "\(Int((route.confidence * 100).rounded()))%")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("How the last turn was routed to a skill")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        controller.send(text)
    }
}

private struct LineView: View {
    let line: ChatModel.Line

    var body: some View {
        switch line.kind {
        case .you:
            HStack { Spacer(minLength: 40); bubble(Color.accentColor.opacity(0.22)) }
        case .voice:
            HStack { bubble(Color.secondary.opacity(0.14)); Spacer(minLength: 40) }
        case .tool:
            Label(line.text, systemImage: "arrow.right.circle").font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(3).textSelection(.enabled)
        case .result:
            Label(line.text, systemImage: "checkmark.circle").font(.caption.monospaced()).foregroundStyle(.tertiary)
                .lineLimit(4).textSelection(.enabled)
        case .note:
            Text(line.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private func bubble(_ color: Color) -> some View {
        Text(line.text).textSelection(.enabled)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(color))
    }
}

// MARK: skills: every harness action, and what each skill uses

private struct SkillsView: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var chat: ChatModel

    var body: some View {
        List {
            Section("Learned skills") {
                if controller.skills.isEmpty {
                    Text("None yet. Teach one by voice or in the chat: “learn a skill called start my day that opens Mail "
                         + "and Calendar and sets the volume to 30”.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(controller.skills) { skill in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(skill.title).font(.headline)
                            Spacer()
                            Button(role: .destructive) { controller.deleteLearned(skill.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Forget this skill")
                        }
                        Text(skill.summary).font(.callout).foregroundStyle(.secondary)
                        ForEach(Array(skill.steps.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step.action) \(step.arguments == "{}" ? "" : step.arguments)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            ForEach(controller.harnesses) { harness in
                Section {
                    if !harness.available {
                        Text(harness.unavailableReason).font(.callout).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if chat.activeSkills.contains(harness.id) {
                            Text("loaded").font(.caption2).foregroundStyle(.green)
                        }
                        FlowText(items: harness.actions.map { ($0.name, $0.description) })
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("\(harness.title) · \(harness.actions.count) actions")
                }
            }
        }
    }
}

/// Action names as small chips, each explaining itself on hover.
private struct FlowText: View {
    let items: [(name: String, description: String)]

    var body: some View {
        Text(items.map(\.name).joined(separator: "  ·  "))
            .font(.caption.monospaced()).foregroundStyle(.secondary)
            .help(items.map { "\($0.name): \($0.description)" }.joined(separator: "\n"))
    }
}

// MARK: settings

private struct SettingsView: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var settings: CompanionSettings
    @State private var keyDrafts: [Provider: String] = [:]
    @State private var jevDraft = ""
    @State private var message = ""

    var body: some View {
        Form {
            Section("Voice") {
                Picker("Model", selection: Binding(get: { settings.provider }, set: { controller.switchProvider(to: $0) })) {
                    ForEach(CompanionSettings.providers, id: \.self) { provider in
                        Text(provider.menuTitle + (settings.hasKey(provider) ? "" : " (no key)")).tag(provider)
                    }
                }
            }
            Section("API keys (stored in your Keychain)") {
                ForEach(CompanionSettings.providers, id: \.self) { provider in
                    HStack {
                        SecureField("\(provider.menuTitle) key\(settings.hasKey(provider) ? " (saved)" : "")",
                                    text: Binding(get: { keyDrafts[provider] ?? "" }, set: { keyDrafts[provider] = $0 }))
                        Button("Save") {
                            message = settings.saveKey(keyDrafts[provider] ?? "", for: provider)
                                ? "Saved the \(provider.menuTitle) key." : "That doesn't look like a key."
                            keyDrafts[provider] = ""
                        }
                        .disabled((keyDrafts[provider] ?? "").isEmpty)
                    }
                }
            }
            Section("Skill routing") {
                Toggle("Route each turn with Jev", isOn: $settings.routeWithJev)
                HStack {
                    SecureField("Jev (TypeSafe) key\(settings.jevKey != nil ? " (saved)" : "")", text: $jevDraft)
                    Button("Save") {
                        message = settings.saveJevKey(jevDraft) ? "Saved the Jev key." : "That doesn't look like a key."
                        jevDraft = ""
                        controller.refreshRouter()
                    }
                    .disabled(jevDraft.isEmpty)
                }
                Button("Use MeetingPulse's Jev key") {
                    message = settings.importJevKeyFromMeetingPulse() ? "Imported the Jev key." : "No MeetingPulse key found."
                    controller.refreshRouter()
                }
                TextField("Jev model", text: $settings.jevModel).onSubmit { controller.refreshRouter() }
                Text(settings.jevRouter == nil ? "Routing by words until Jev has a key." : "Routing with \(settings.jevModel).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Powerful controls") {
                Toggle("AppleScript (each script needs your spoken yes)",
                       isOn: Binding(get: { controller.appleScriptOn }, set: { controller.setAppleScript($0) }))
                Toggle("Shell commands (each command needs your spoken yes)",
                       isOn: Binding(get: { controller.shellOn }, set: { controller.setShell($0) }))
                HStack {
                    Button("Restart now") { controller.restart() }
                    Button("Open skills folder") { controller.openSkillsFolder() }
                }
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
