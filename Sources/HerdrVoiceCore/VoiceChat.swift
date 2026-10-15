import Foundation

// The voice chat: every turn, the user's and hers, is a voice note with its audio, waveform, duration and
// transcript, kept on disk until the user deletes it (`~/.vox/conversations/<date>/<conversation>/`).

/// One voice note: a turn's audio (24 kHz PCM16 mono, as sent and as played) and its transcript.
public struct VoiceClip: Codable, Equatable, Sendable, Identifiable {
    public enum Side: String, Codable, Sendable { case user, vox }

    /// Its place in the conversation, from 1.
    public var id: Int
    public var side: Side
    /// The transcript; nil until it's known (a user turn's transcript can arrive after her reply starts).
    public var text: String?
    public var start: Date
    /// Seconds of audio; 0 for a typed turn or a reply that came as text only.
    public var seconds: Double
    /// The audio file's name in the conversation's folder, once written.
    public var audio: String?
    /// 0...1 loudness bars for the bubble's waveform.
    public var waveform: [Float]
    public var typed: Bool

    public init(id: Int, side: Side, text: String? = nil, start: Date, seconds: Double = 0, audio: String? = nil,
                waveform: [Float] = [], typed: Bool = false) {
        self.id = id
        self.side = side
        self.text = text
        self.start = start
        self.seconds = seconds
        self.audio = audio
        self.waveform = waveform
        self.typed = typed
    }
}

/// Builds the voice notes from what the session sends and plays and the transcripts it reports, which don't arrive
/// in step: the mic's speech comes first, its transcript maybe only after her reply has started, and a reply's audio
/// keeps streaming after its transcript. So audio opens a note and transcripts fill the oldest note of that side
/// still without one. Her reply is one note per spoken item; a new item, or the user speaking again, closes it.
public struct VoiceChatAssembler: Sendable {
    public struct Note: Equatable, Sendable {
        public var clip: VoiceClip
        public var pcm = Data()
        /// Still taking audio.
        public var open: Bool
        /// The reply's item, for her notes.
        public var item: String?
    }

    public private(set) var notes: [Note] = []
    private var openUser: Int?
    private var openReply: Int?
    /// Typed turns, whose echo as a transcript isn't a spoken turn.
    private var typedEchoes: [String] = []

    public init() {}

    public var isEmpty: Bool { notes.isEmpty }

    /// Speech the gate sent to the provider.
    public mutating func mic(_ pcm: Data, at time: Date) {
        guard !pcm.isEmpty else { return }
        if openReply != nil { closeReply() } // talking over her, or the next turn: her note is over
        let index = openUser ?? add(.user, at: time)
        openUser = index
        notes[index].pcm.append(pcm)
    }

    /// Her audio as it is played, item by item.
    public mutating func reply(_ pcm: Data, item: String, at time: Date) {
        guard !pcm.isEmpty else { return }
        closeUser()
        if let index = openReply, notes[index].item != item { closeReply() }
        let index = openReply ?? add(.vox, at: time, item: item)
        openReply = index
        notes[index].pcm.append(pcm)
    }

    /// The user's words, spoken (as transcribed) or the echo of a typed turn.
    public mutating func userText(_ text: String, at time: Date) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let echo = typedEchoes.firstIndex(of: text) {
            typedEchoes.remove(at: echo)
            return
        }
        if let index = notes.firstIndex(where: { $0.clip.side == .user && $0.clip.text == nil && !$0.clip.typed }) {
            notes[index].clip.text = text
            if index == openUser { closeUser() } // transcribed: that utterance is over
        } else {
            let index = add(.user, at: time)
            notes[index].clip.text = text
            notes[index].open = false
        }
    }

    /// A typed turn: a note without audio. The session reports it back as the user's words, which is skipped.
    public mutating func typed(_ text: String, at time: Date) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        closeUser()
        let index = add(.user, at: time)
        notes[index].clip.text = text
        notes[index].clip.typed = true
        notes[index].open = false
        typedEchoes.append(text)
    }

    /// Her words for the oldest reply still without them, or a reply that came as text only.
    public mutating func voiceText(_ text: String, at time: Date) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let index = notes.firstIndex(where: { $0.clip.side == .vox && $0.clip.text == nil }) {
            notes[index].clip.text = text
        } else {
            let index = add(.vox, at: time)
            notes[index].clip.text = text
            notes[index].open = false
        }
    }

    /// The conversation is over: every note is closed.
    public mutating func finish() {
        closeUser()
        closeReply()
    }

    /// The closed notes with audio, for saving.
    public var closedWithAudio: [Note] { notes.filter { !$0.open && !$0.pcm.isEmpty } }

    /// The clips as they stand: an open note's duration and waveform are from its audio so far.
    public var clips: [VoiceClip] {
        notes.map { note in
            guard note.open, !note.pcm.isEmpty else { return note.clip }
            var clip = note.clip
            clip.seconds = PCM.seconds(note.pcm)
            clip.waveform = Waveform.bars(note.pcm)
            return clip
        }
    }

    /// A note's audio so far, by clip id.
    public func pcm(of id: Int) -> Data? { notes.first { $0.clip.id == id }?.pcm }

    private mutating func add(_ side: VoiceClip.Side, at time: Date, item: String? = nil) -> Int {
        notes.append(Note(clip: VoiceClip(id: notes.count + 1, side: side, start: time), open: true, item: item))
        return notes.count - 1
    }

    private mutating func closeUser() {
        guard let index = openUser else { return }
        seal(index)
        openUser = nil
    }

    private mutating func closeReply() {
        guard let index = openReply else { return }
        seal(index)
        openReply = nil
    }

    private mutating func seal(_ index: Int) {
        notes[index].open = false
        notes[index].clip.seconds = PCM.seconds(notes[index].pcm)
        notes[index].clip.waveform = Waveform.bars(notes[index].pcm)
    }
}

/// 24 kHz PCM16 mono, the app's one audio format.
public enum PCM {
    public static let rate = 24_000

    public static func seconds(_ pcm: Data) -> Double { Double(pcm.count / 2) / Double(rate) }

    /// A WAV file around the samples.
    public static func wav(_ pcm: Data, rate: Int = rate) -> Data {
        var out = Data(capacity: 44 + pcm.count)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + pcm.count))
        out.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16)
        u16(1) // PCM
        u16(1) // mono
        u32(UInt32(rate))
        u32(UInt32(rate * 2))
        u16(2)
        u16(16)
        out.append(contentsOf: Array("data".utf8))
        u32(UInt32(pcm.count))
        out.append(pcm)
        return out
    }

    /// The samples of a WAV this app wrote (a 44-byte header), or nil.
    public static func samples(ofWAV data: Data) -> Data? {
        guard data.count >= 44, data.prefix(4) == Data("RIFF".utf8) else { return nil }
        return data.dropFirst(44)
    }
}

public enum Waveform {
    public static let barCount = 28

    /// Loudness per bar, 0...1: RMS per slice, scaled to the loudest slice, with a floor so silence still shows.
    public static func bars(_ pcm: Data, count: Int = barCount) -> [Float] {
        let samples = pcm.count / 2
        guard samples > 0, count > 0 else { return [] }
        var rms = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for bar in 0..<count {
                let from = samples * bar / count, to = max(from + 1, samples * (bar + 1) / count)
                var sum: Float = 0
                for i in from..<min(to, samples) {
                    let v = Float(Int16(littleEndian: s[i])) / 32768
                    sum += v * v
                }
                rms[bar] = (sum / Float(to - from)).squareRoot()
            }
        }
        let peak = rms.max() ?? 0
        guard peak > 0 else { return rms.map { _ in 0.08 } }
        return rms.map { max(0.08, ($0 / peak).squareRoot()) }
    }
}

/// One saved conversation's transcript: `transcript.json` beside its audio files.
public struct ConversationTranscript: Codable, Equatable, Sendable {
    /// `<date>/<conversation>`, its folder under the conversations root.
    public var id: String
    public var started: Date
    public var ended: Date?
    /// The voice model it ran on.
    public var provider: String
    public var clips: [VoiceClip]

    public init(id: String, started: Date, ended: Date? = nil, provider: String, clips: [VoiceClip] = []) {
        self.id = id
        self.started = started
        self.ended = ended
        self.provider = provider
        self.clips = clips
    }

    /// What it was about: the user's first words.
    public var title: String {
        clips.first { $0.side == .user && !($0.text ?? "").isEmpty }?.text ?? "Conversation"
    }

    public var talkSeconds: Double { clips.reduce(0) { $0 + $1.seconds } }
}

/// The conversations on disk: `<root>/<yyyy-MM-dd>/<HHmmss-xxxx>/` each with `transcript.json` and one WAV per voice
/// note. Kept until the user deletes one or all. Thread-safe: it only touches files.
public struct ConversationStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// A new conversation's id, from when it started.
    public static func newID(at date: Date, suffix: String = String(UUID().uuidString.prefix(4)).lowercased()) -> String {
        let day = DateFormatter(), time = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        time.locale = day.locale
        day.dateFormat = "yyyy-MM-dd"
        time.dateFormat = "HHmmss"
        return "\(day.string(from: date))/\(time.string(from: date))-\(suffix)"
    }

    public func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    public static func audioName(_ clip: VoiceClip) -> String {
        String(format: "%03d-%@.wav", clip.id, clip.side.rawValue)
    }

    /// Writes a note's audio; returns its file name.
    @discardableResult
    public func saveAudio(_ pcm: Data, for clip: VoiceClip, in id: String) throws -> String {
        let folder = folder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Self.audioName(clip)
        try PCM.wav(pcm).write(to: folder.appendingPathComponent(name), options: .atomic)
        return name
    }

    public func save(_ transcript: ConversationTranscript) throws {
        let folder = folder(transcript.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(transcript).write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
    }

    public func load(_ id: String) -> ConversationTranscript? {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent("transcript.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ConversationTranscript.self, from: data)
    }

    public func audioURL(_ clip: VoiceClip, in id: String) -> URL? {
        clip.audio.map { folder(id).appendingPathComponent($0) }
    }

    /// Every saved conversation, newest first.
    public func list(limit: Int = .max) -> [ConversationTranscript] {
        let fm = FileManager.default
        guard let days = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var found: [ConversationTranscript] = []
        for day in days.sorted(by: >) where !day.hasPrefix(".") {
            let conversations = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(day).path)) ?? []
            for name in conversations.sorted(by: >) where !name.hasPrefix(".") {
                if let transcript = load("\(day)/\(name)") { found.append(transcript) }
                if found.count >= limit { return found }
            }
        }
        return found.sorted { $0.started > $1.started }
    }

    /// Deletes one conversation (and its day folder, once empty).
    public func delete(_ id: String) throws {
        let fm = FileManager.default
        let folder = folder(id)
        guard folder.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        let day = folder.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: day.path))?.filter({ !$0.hasPrefix(".") }).isEmpty == true {
            try? fm.removeItem(at: day)
        }
    }

    /// Deletes every conversation.
    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}

public extension WireFrame {
    /// The mic audio in an outgoing frame, if it carries any: what the session actually sent the provider, whichever
    /// wire encoded it (`input_audio_buffer.append`, Gemini's `realtimeInput.audio`, Local's `input.append`).
    static func micAudio(in frame: [String: Any]) -> String? {
        switch frame["type"] as? String {
        case "input_audio_buffer.append", "input.append": return frame["audio"] as? String
        case nil:
            let input = frame["realtimeInput"] as? [String: Any]
            return (input?["audio"] as? [String: Any])?["data"] as? String
        default: return nil
        }
    }
}
