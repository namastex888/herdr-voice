import AVFoundation
import HerdrVoiceCore
import SwiftUI
import VoiceEngine

/// Keeps the voice chat: the mic audio the session sends and her audio as it plays become voice notes with their
/// transcripts (`VoiceChatAssembler`), saved under `~/.vox/conversations/<date>/<conversation>/` as WAV files and a
/// `transcript.json`, and kept until the user deletes them. Nothing muted or paused is kept: the session sends no mic
/// audio then, plays nothing while paused, and `micAllowed` drops whatever might still be on its way.
@MainActor final class ConversationRecorder: ObservableObject {
    /// In always-on mode there are no conversations to end, so one ends after this long without a word.
    static let quietEnd: TimeInterval = 180
    /// The views catch up with the audio at most this often.
    static let publishInterval: TimeInterval = 0.25

    let store: ConversationStore
    /// The current (or last) conversation's notes, as they stand.
    @Published private(set) var clips: [VoiceClip] = []
    /// When the current (or last) conversation started.
    @Published private(set) var started: Date?
    @Published private(set) var conversationID: String?
    /// The saved conversations, newest first (`refreshSaved`).
    @Published private(set) var saved: [ConversationTranscript] = []
    /// The voice model the conversation runs on, written into its transcript.
    var provider = ""
    /// Whether mic audio may be kept now: false while muted or paused.
    var micAllowed: () -> Bool = { true }
    /// Seconds of speech, per side, as they come: the talk-time metric.
    var onTalk: ((VoiceClip.Side, Double) -> Void)?

    private var assembler = VoiceChatAssembler()
    private var savedAudio: [Int: String] = [:]
    private var lastActivity = Date.distantPast
    private var publishScheduled = false
    private var flushScheduled = false
    private let io = DispatchQueue(label: "voice-companion.conversations", qos: .utility)

    init(store: ConversationStore) {
        self.store = store
    }

    var inProgress: Bool { conversationID != nil && !assembler.isEmpty && endedAt == nil }
    private var endedAt: Date?

    // MARK: what comes in

    /// Mic audio as the session sent it.
    func mic(_ pcm: Data, at now: Date = Date()) {
        guard micAllowed() else { return }
        begin(at: now)
        assembler.mic(pcm, at: now)
        onTalk?(.user, PCM.seconds(pcm))
        changed(at: now, saving: false)
    }

    /// Her audio as it is played.
    func played(_ pcm: Data, item: String, at now: Date = Date()) {
        begin(at: now)
        assembler.reply(pcm, item: item, at: now)
        onTalk?(.vox, PCM.seconds(pcm))
        changed(at: now, saving: false)
    }

    /// The session's report of what was said: the transcripts of both sides.
    func heard(_ event: SessionEvent, at now: Date = Date()) {
        switch event {
        case .you(let text):
            begin(at: now)
            assembler.userText(text, at: now)
        case .voice(let text):
            begin(at: now)
            assembler.voiceText(text, at: now)
        default:
            return
        }
        changed(at: now, saving: true)
    }

    /// A typed turn, before the session echoes it back as the user's words.
    func typed(_ text: String, at now: Date = Date()) {
        begin(at: now)
        assembler.typed(text, at: now)
        changed(at: now, saving: true)
    }

    /// The conversation is over (the follow-up window closed, Esc, a disconnect): every note is closed and saved;
    /// the next word starts a new conversation. The notes stay on screen until then.
    func end(at now: Date = Date()) {
        guard conversationID != nil, endedAt == nil else { return }
        assembler.finish()
        endedAt = now
        publish()
        flush()
    }

    /// Each frame in always-on mode: a conversation nobody has spoken in for `quietEnd` ends.
    func tick(at now: Date) {
        if inProgress, now.timeIntervalSince(lastActivity) > Self.quietEnd { end(at: now) }
    }

    // MARK: the current conversation

    private func begin(at now: Date) {
        lastActivity = now
        guard conversationID == nil || endedAt != nil else { return }
        assembler = VoiceChatAssembler()
        savedAudio = [:]
        endedAt = nil
        conversationID = ConversationStore.newID(at: now)
        started = now
        clips = []
    }

    private func changed(at now: Date, saving: Bool) {
        lastActivity = now
        if !publishScheduled {
            publishScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishInterval) { [weak self] in
                MainActor.assumeIsolated {
                    self?.publishScheduled = false
                    self?.publish()
                }
            }
        }
        // Audio alone changes nothing on disk until its note closes; a transcript or a closed note does.
        if saving || assembler.closedWithAudio.contains(where: { savedAudio[$0.clip.id] == nil }) { scheduleFlush() }
    }

    private func publish() {
        let next = currentClips()
        if next != clips { clips = next }
    }

    private func currentClips() -> [VoiceClip] {
        assembler.clips.map { clip in
            var clip = clip
            clip.audio = savedAudio[clip.id]
            return clip
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.flushScheduled = false
                self?.flush()
            }
        }
    }

    /// Writes the closed notes' audio and the transcript, off the main thread.
    private func flush() {
        guard let id = conversationID, let started else { return }
        let toSave = assembler.closedWithAudio.filter { savedAudio[$0.clip.id] == nil }
        for note in toSave { savedAudio[note.clip.id] = ConversationStore.audioName(note.clip) }
        let transcript = ConversationTranscript(id: id, started: started, ended: endedAt, provider: provider,
                                                clips: currentClips())
        let store = store
        let audio = toSave.map { ($0.pcm, $0.clip) }
        io.async { [weak self] in
            for (pcm, clip) in audio { _ = try? store.saveAudio(pcm, for: clip, in: id) }
            try? store.save(transcript)
            DispatchQueue.main.async { [weak self] in self?.refreshSaved() }
        }
        publish()
    }

    /// A live note's audio, for replay before it's written.
    func liveAudio(_ clip: VoiceClip) -> Data? { assembler.pcm(of: clip.id) }

    // MARK: saved conversations

    func refreshSaved() {
        let store = store
        io.async { [weak self] in
            let list = store.list(limit: 200)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.saved != list else { return }
                self.saved = list
            }
        }
    }

    func delete(_ id: String) {
        if id == conversationID { forgetCurrent() }
        let store = store
        io.async { [weak self] in
            try? store.delete(id)
            DispatchQueue.main.async { [weak self] in self?.refreshSaved() }
        }
        saved.removeAll { $0.id == id }
    }

    func deleteAll() {
        forgetCurrent()
        let store = store
        io.async { [weak self] in
            try? store.deleteAll()
            DispatchQueue.main.async { [weak self] in self?.refreshSaved() }
        }
        saved = []
    }

    /// Stops keeping the current conversation (it was deleted): its next words start a new one.
    private func forgetCurrent() {
        assembler = VoiceChatAssembler()
        savedAudio = [:]
        conversationID = nil
        started = nil
        endedAt = nil
        clips = []
    }

    /// Waits for every write so far (the self-test reads the files back).
    func drain() { io.sync {} }
}

/// Plays a voice note back: from its file, or a live note's audio before it is written.
@MainActor final class VoiceNotePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// What is playing: a conversation id and clip id.
    @Published private(set) var playing: String?
    private var player: AVAudioPlayer?

    static func key(_ conversation: String?, _ clip: VoiceClip) -> String { "\(conversation ?? "live")#\(clip.id)" }

    func toggle(_ key: String, file: URL?, pcm: Data?) {
        if playing == key { return stop() }
        stop()
        let next: AVAudioPlayer?
        if let file {
            next = try? AVAudioPlayer(contentsOf: file)
        } else if let pcm, !pcm.isEmpty {
            next = try? AVAudioPlayer(data: PCM.wav(pcm))
        } else {
            next = nil
        }
        guard let next else { return }
        next.delegate = self
        guard next.play() else { return }
        player = next
        playing = key
    }

    func stop() {
        player?.stop()
        player = nil
        if playing != nil { playing = nil }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stop() }
    }
}
