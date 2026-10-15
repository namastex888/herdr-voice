import Foundation
import Testing
@testable import HerdrVoiceCore

private let t0 = Date(timeIntervalSince1970: 2_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
/// `ms` milliseconds of a 24 kHz tone at `level` (0...1).
private func tone(_ ms: Int, level: Double = 0.5) -> Data {
    let count = PCM.rate * ms / 1000
    var samples = (0..<count).map { Int16(level * 32767 * sin(Double($0) * 0.06)).littleEndian }
    return Data(bytes: &samples, count: count * 2)
}

@Test func aSpokenTurnAndHerReplyBecomeTwoVoiceNotesWithTheirTranscripts() {
    var chat = VoiceChatAssembler()
    chat.mic(tone(20), at: at(0))
    chat.mic(tone(20), at: at(0.02))
    chat.reply(tone(40), item: "a", at: at(1))
    // OpenAI: the user's transcript arrives after her reply started, her own before her audio ends.
    chat.voiceText("It's sunny.", at: at(1.2))
    chat.userText("What's the weather?", at: at(1.3))
    chat.reply(tone(40), item: "a", at: at(1.4))
    chat.finish()
    #expect(chat.clips.map(\.side) == [.user, .vox])
    #expect(chat.clips.map(\.text) == ["What's the weather?", "It's sunny."])
    #expect(abs(chat.clips[0].seconds - 0.04) < 0.001 && abs(chat.clips[1].seconds - 0.08) < 0.001)
    #expect(chat.clips.allSatisfy { $0.waveform.count == Waveform.barCount })
    #expect(chat.closedWithAudio.count == 2)
}

@Test func eachSpokenItemOfHersIsItsOwnNoteAndTranscriptsFillThemInOrder() {
    var chat = VoiceChatAssembler()
    chat.mic(tone(20), at: at(0))
    chat.reply(tone(20), item: "a", at: at(1))
    chat.reply(tone(20), item: "b", at: at(2)) // after a tool call, a second reply
    chat.voiceText("Opening Safari.", at: at(2.1))
    chat.voiceText("Done.", at: at(2.2))
    #expect(chat.clips.map(\.text) == [nil, "Opening Safari.", "Done."])
    #expect(chat.notes[1].open == false && chat.notes[2].open)
}

@Test func talkingOverHerClosesHerNoteAndStartsYours() {
    var chat = VoiceChatAssembler()
    chat.reply(tone(20), item: "a", at: at(0))
    chat.mic(tone(20), at: at(0.5))
    chat.reply(tone(20), item: "a", at: at(0.6)) // late audio of the cut reply: a new note, not yours
    #expect(chat.clips.map(\.side) == [.vox, .user, .vox])
    #expect(chat.notes[1].open == false)
}

@Test func aTypedTurnIsANoteWithoutAudioAndItsEchoIsNotASecondTurn() {
    var chat = VoiceChatAssembler()
    chat.typed("open mail", at: at(0))
    chat.userText("open mail", at: at(0.01))
    chat.voiceText("Opened Mail.", at: at(1))
    #expect(chat.clips.count == 2)
    #expect(chat.clips[0].typed && chat.clips[0].seconds == 0 && chat.clips[1].text == "Opened Mail.")
    #expect(chat.closedWithAudio.isEmpty)
}

@Test func aTranscriptWithoutAudioStillShowsAsANote() {
    var chat = VoiceChatAssembler()
    chat.userText("hello", at: at(0))
    #expect(chat.clips.map(\.text) == ["hello"] && chat.notes[0].open == false)
}

@Test func wavFilesRoundTripAndWaveformsFollowLoudness() {
    let pcm = tone(100)
    let wav = PCM.wav(pcm)
    #expect(wav.count == 44 + pcm.count && wav.prefix(4) == Data("RIFF".utf8))
    #expect(PCM.samples(ofWAV: wav) == pcm)
    let bars = Waveform.bars(tone(50, level: 0.05) + tone(50, level: 0.9), count: 4)
    #expect(bars.count == 4 && bars[0] < bars[3] && bars[3] == 1)
    #expect(Waveform.bars(Data(count: 960), count: 3) == [0.08, 0.08, 0.08])
}

@Test func conversationsAreKeptUntilDeletedOneOrAll() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vox-chat-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(root: root)
    var chat = VoiceChatAssembler()
    chat.mic(tone(60), at: at(0))
    chat.userText("first", at: at(1))
    chat.finish()
    let first = ConversationStore.newID(at: at(0), suffix: "aaaa")
    var transcript = ConversationTranscript(id: first, started: at(0), provider: "grok", clips: chat.clips)
    for note in chat.closedWithAudio {
        let name = try store.saveAudio(note.pcm, for: note.clip, in: first)
        transcript.clips[note.clip.id - 1].audio = name
    }
    try store.save(transcript)
    let second = ConversationStore.newID(at: at(3600), suffix: "bbbb")
    try store.save(ConversationTranscript(id: second, started: at(3600), provider: "openai",
                                          clips: [VoiceClip(id: 1, side: .user, text: "second", start: at(3600))]))
    #expect(store.list().map(\.id) == [second, first])
    let loaded = try #require(store.load(first))
    #expect(loaded == transcript && loaded.title == "first")
    let file = try #require(store.audioURL(loaded.clips[0], in: first))
    #expect(PCM.samples(ofWAV: try Data(contentsOf: file)) == tone(60))

    try store.delete(first)
    #expect(store.list().map(\.id) == [second])
    try store.delete("../../etc") // outside the root: ignored
    try store.deleteAll()
    #expect(store.list().isEmpty && !FileManager.default.fileExists(atPath: root.path))
}

@Test("the audio a wire sends can be read back from its frames, and nothing else reads as audio",
      arguments: [Provider.openai, .grok, .gemini, .local])
func micAudioIsReadFromEachWiresFrames(_ provider: Provider) {
    let wire = provider.makeWire(environment: [:])
    // Local streams audio only inside an utterance.
    _ = wire.encode(.inputStarted(utteranceID: "u1"))
    let frames = wire.encode(.appendAudio("QUJD"))
    #expect(frames.compactMap(WireFrame.micAudio(in:)) == ["QUJD"])
    let other = wire.encode(.userText("hi", expectsReply: true)) + wire.encode(.requestReply) + wire.encode(.audioPaused)
    #expect(other.compactMap(WireFrame.micAudio(in:)).isEmpty)
}
