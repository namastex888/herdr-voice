import AppKit
import HerdrVoiceCore
import SwiftUI

// The voice chat, WhatsApp style: every turn, yours and hers, is a voice note with its waveform, duration, ▶ replay
// and transcript, with what she ran and asked in between; a toggle shows transcripts only. Past conversations are
// kept until you delete one or all.

/// The transcript-only toggle's key (a view preference, not part of her configuration).
let transcriptOnlyKey = "VoiceCompanion.transcriptOnly"

/// One row of the chat: a voice note, or another line (a tool, a result, her question, a note).
enum ChatItem: Identifiable {
    case note(VoiceClip)
    case line(ChatModel.Line)

    var id: String {
        switch self {
        case .note(let clip): "note-\(clip.id)"
        case .line(let line): line.id.uuidString
        }
    }

    var time: Date {
        switch self {
        case .note(let clip): clip.start
        case .line(let line): line.time
        }
    }
}

/// The current conversation as voice notes, the other lines in between, and typing below.
struct VoiceChatScreen: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var chat: ChatModel
    @ObservedObject var recorder: ConversationRecorder
    @ObservedObject var player: VoiceNotePlayer
    @ObservedObject var model: PhoneModel
    @AppStorage(transcriptOnlyKey) private var transcriptOnly = false
    @State private var draft = ""
    @FocusState private var typing: Bool
    @Environment(\.phoneTheme) private var theme
    @Environment(\.phoneSnapshot) private var snapshot

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: controller.name, back: { model.go(.home) }) {
                HStack(spacing: 2) {
                    TranscriptToggle(transcriptOnly: $transcriptOnly)
                    Button { model.go(.conversations) } label: {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 15, weight: .semibold))
                            .frame(width: 32, height: 32).contentShape(Circle())
                    }
                    .buttonStyle(.plain).help("Past conversations")
                }
            }
            skillStrip
            ScrollViewReader { scroller in
                PhoneScroll {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if items.isEmpty {
                            Text("Tap \(controller.settings.activationKey.title) and talk, or type below. Every turn "
                                 + "shows here as a voice note you can play back, with its transcript.")
                                .font(.system(size: 13)).foregroundStyle(theme.onSurfaceVariant)
                                .padding(16)
                                .background(RoundedRectangle(cornerRadius: 20).fill(theme.surfaceContainer))
                                .padding(.top, 12)
                        }
                        ForEach(snapshot ? Array(items.suffix(8)) : items) { item in
                            row(item).id(item.id)
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
                .onChange(of: items.last?.id) { _, last in
                    if let last { withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(last, anchor: .bottom) } }
                }
            }
            inputBar.padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 30)
        }
        .background(theme.surface)
    }

    /// The notes and the lines since the conversation began, in order.
    private var items: [ChatItem] {
        let since = recorder.started.map { $0.addingTimeInterval(-1) } ?? .distantPast
        let lines = chat.conversation.filter { $0.kind != .you && $0.kind != .voice && $0.time >= since }
        return (recorder.clips.map(ChatItem.note) + lines.map(ChatItem.line)).sorted { $0.time < $1.time }
    }

    @ViewBuilder private func row(_ item: ChatItem) -> some View {
        switch item {
        case .note(let clip):
            let key = VoiceNotePlayer.key(recorder.conversationID, clip)
            VoiceNoteView(clip: clip, transcriptOnly: transcriptOnly, playing: player.playing == key) {
                player.toggle(key, file: clip.audio.flatMap { _ in
                    recorder.conversationID.flatMap { recorder.store.audioURL(clip, in: $0) }
                }, pcm: recorder.liveAudio(clip))
            }
        case .line(let line):
            MessageCard(line: line)
        }
    }

    private var skillStrip: some View {
        HStack(spacing: 6) {
            ForEach(chat.activeSkills.prefix(3), id: \.self) { id in
                Text(controller.title(ofSkill: id)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(id == chat.activeSkills.first ? theme.secondaryContainer : theme.surfaceContainerHigh))
                    .foregroundStyle(theme.onSecondaryContainer)
            }
            Spacer(minLength: 0)
            if let route = chat.lastRoute {
                Text(route.skill == RouteDecision.chat ? "just talking"
                     : "\(route.source == .jev ? "Jev" : "words") \(Int((route.confidence * 100).rounded()))%")
                    .font(.system(size: 10)).foregroundStyle(theme.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 4)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Group {
                if snapshot {
                    Text("Message \(controller.name)").opacity(0.55).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Message \(controller.name)", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(1...4).focused($typing).onSubmit(send)
                }
            }
            .font(.system(size: 14)).foregroundStyle(theme.onSurface)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(Capsule().fill(theme.surfaceContainerHighest))
            let empty = draft.trimmingCharacters(in: .whitespaces).isEmpty
            Button(action: empty ? { controller.talkTapped() } : send) {
                Image(systemName: empty ? "mic.fill" : "arrow.up").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.onPrimary)
                    .frame(width: 42, height: 42).background(Circle().fill(theme.primary))
            }
            .buttonStyle(.plain).help(empty ? "Talk" : "Send")
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        controller.send(text)
    }
}

/// Voice notes or transcripts only.
struct TranscriptToggle: View {
    @Binding var transcriptOnly: Bool

    var body: some View {
        Button { transcriptOnly.toggle() } label: {
            Image(systemName: transcriptOnly ? "waveform" : "text.alignleft").font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32).contentShape(Circle())
        }
        .buttonStyle(.plain).help(transcriptOnly ? "Show voice notes" : "Transcripts only")
    }
}

/// A voice note: ▶ replay, the waveform, the duration and the transcript; yours on the right, hers on the left.
struct VoiceNoteView: View {
    let clip: VoiceClip
    let transcriptOnly: Bool
    let playing: Bool
    let play: () -> Void
    @Environment(\.phoneTheme) private var theme

    private var mine: Bool { clip.side == .user }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 6) {
                if hasAudio {
                    HStack(spacing: 8) {
                        Button(action: play) {
                            Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 12, weight: .bold))
                                .foregroundStyle(mine ? theme.primaryContainer : theme.onPrimary)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(mine ? theme.onPrimaryContainer : theme.primary))
                        }
                        .buttonStyle(.plain).help(playing ? "Stop" : "Play")
                        WaveformBars(bars: clip.waveform, tint: mine ? theme.onPrimaryContainer : theme.primary)
                            .frame(height: 26)
                        Text(Self.duration(clip.seconds)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(text.opacity(0.75))
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if clip.typed { Image(systemName: "keyboard").font(.system(size: 10)).opacity(0.7) }
                    Text(clip.text ?? "…").font(.system(size: transcriptOnly ? 14 : 13)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(clip.text == nil ? text.opacity(0.6) : text)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(width: hasAudio ? 224 : nil, alignment: .leading)
            .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: mine ? 18 : 5,
                                               bottomTrailingRadius: mine ? 5 : 18, topTrailingRadius: 18,
                                               style: .continuous).fill(mine ? theme.primaryContainer : theme.surfaceContainerHigh))
            if !mine { Spacer(minLength: 36) }
        }
    }

    private var text: Color { mine ? theme.onPrimaryContainer : theme.onSurface }
    private var hasAudio: Bool { !transcriptOnly && clip.seconds > 0 }

    static func duration(_ seconds: Double) -> String {
        let whole = max(1, Int(seconds.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// A voice note's loudness as bars.
struct WaveformBars: View {
    let bars: [Float]
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let count = max(bars.count, 1)
            let width = max(1.5, geometry.size.width / CGFloat(count) - 1.5)
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                    Capsule().fill(tint.opacity(0.85))
                        .frame(width: width, height: max(3, geometry.size.height * CGFloat(level)))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: 70)
    }
}

// MARK: past conversations

/// Every kept conversation, newest first; open one to replay it, or delete them all.
struct ConversationsScreen: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var recorder: ConversationRecorder
    @ObservedObject var model: PhoneModel
    @State private var confirmDeleteAll = false
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Conversations", back: { model.go(.messages) }) {
                if !recorder.saved.isEmpty {
                    Button { confirmDeleteAll.toggle() } label: {
                        Image(systemName: "trash").font(.system(size: 15, weight: .semibold))
                            .frame(width: 32, height: 32).contentShape(Circle())
                    }
                    .buttonStyle(.plain).help("Delete all conversations")
                }
            }
            PhoneScroll {
                VStack(alignment: .leading, spacing: 8) {
                    if confirmDeleteAll {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Delete every conversation, its audio and transcript? This can't be undone.")
                                .font(.system(size: 13))
                            HStack {
                                Button("Delete all") {
                                    recorder.deleteAll()
                                    confirmDeleteAll = false
                                }
                                .buttonStyle(TonalButton(destructive: true))
                                Button("Keep") { confirmDeleteAll = false }
                                    .buttonStyle(TonalButton())
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 18).fill(theme.error.opacity(0.16)))
                        .foregroundStyle(theme.onSurface)
                    }
                    if recorder.saved.isEmpty {
                        Text("No conversations kept yet. Each one is kept here, with its audio, until you delete it.")
                            .font(.system(size: 13)).foregroundStyle(theme.onSurfaceVariant).padding(16)
                    }
                    ForEach(recorder.saved, id: \.id) { transcript in
                        ConversationRow(transcript: transcript) { model.go(.conversation(transcript.id)) }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 30)
            }
        }
        .background(theme.surface)
        .onAppear { recorder.refreshSaved() }
    }
}

struct ConversationRow: View {
    let transcript: ConversationTranscript
    /// Its own card; off inside a card that already has one.
    var carded = true
    let open: () -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .frame(width: 34, height: 34).background(Circle().fill(theme.primaryContainer))
                VStack(alignment: .leading, spacing: 2) {
                    Text(transcript.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .foregroundStyle(theme.onSurface)
                    Text("\(transcript.started.formatted(.dateTime.weekday(.abbreviated).hour().minute())) · "
                         + "\(transcript.clips.count) notes · \(VoiceNoteView.duration(transcript.talkSeconds))")
                        .font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant)
            }
            .padding(carded ? 10 : 0)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(carded ? theme.surfaceContainer : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One kept conversation, to replay note by note or delete.
struct SavedConversationScreen: View {
    @ObservedObject var recorder: ConversationRecorder
    @ObservedObject var player: VoiceNotePlayer
    @ObservedObject var model: PhoneModel
    let id: String
    @AppStorage(transcriptOnlyKey) private var transcriptOnly = false
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        let transcript = recorder.saved.first { $0.id == id } ?? recorder.store.load(id)
        VStack(spacing: 0) {
            TopBar(title: transcript?.started.formatted(.dateTime.weekday(.abbreviated).day().hour().minute())
                   ?? "Conversation", back: { model.go(.conversations) }) {
                HStack(spacing: 2) {
                    TranscriptToggle(transcriptOnly: $transcriptOnly)
                    Button {
                        player.stop()
                        recorder.delete(id)
                        model.go(.conversations)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 15, weight: .semibold))
                            .frame(width: 32, height: 32).contentShape(Circle())
                    }
                    .buttonStyle(.plain).help("Delete this conversation")
                }
            }
            PhoneScroll {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let transcript {
                        ForEach(transcript.clips) { clip in
                            let key = VoiceNotePlayer.key(id, clip)
                            VoiceNoteView(clip: clip, transcriptOnly: transcriptOnly, playing: player.playing == key) {
                                player.toggle(key, file: recorder.store.audioURL(clip, in: id), pcm: nil)
                            }
                        }
                    } else {
                        Text("This conversation was deleted.").font(.system(size: 13))
                            .foregroundStyle(theme.onSurfaceVariant).padding(16)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 30)
            }
        }
        .background(theme.surface)
    }
}
