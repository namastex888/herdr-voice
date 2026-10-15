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
    @ObservedObject var keys: CompanionKeys

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch controller.tab {
            case .chat: ChatView(controller: controller, chat: chat)
            case .skills: SkillsView(controller: controller, chat: chat)
            case .settings: SettingsView(controller: controller, keys: keys)
            }
        }
        .frame(minWidth: 340, minHeight: 420)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(chat.connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                .help(chat.connected ? "Connected" : "Not connected; it opens when you speak or type")
            VStack(alignment: .leading, spacing: 0) {
                Text(controller.name).font(.headline).lineLimit(1)
                Text(chat.provider.menuTitle).font(.caption).foregroundStyle(.secondary)
            }
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
                            Text("Talk any time, or type below. \(controller.name) is new here: give a first task (“open Safari”, "
                                 + "“set the volume to 30”) or teach one (“when I say start my day, open Mail and Calendar”). "
                                 + "Nothing about her changes without your yes.")
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
                TextField("Type to \(controller.name)…", text: $draft, axis: .vertical)
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
        case .ask:
            Label(line.text, systemImage: "questionmark.circle.fill").font(.callout).foregroundStyle(.orange)
                .textSelection(.enabled)
        case .change:
            Label(line.text, systemImage: "sparkles").font(.callout).foregroundStyle(.green)
                .textSelection(.enabled)
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
