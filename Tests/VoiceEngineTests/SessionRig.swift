import Foundation
import HerdrVoiceCore
@testable import VoiceEngine

/// The provider's end of one connection: keeps every frame the session sends, in order, and plays the server's
/// events back. Nothing touches the network.
final class FakeSocket: SessionSocket, @unchecked Sendable { // every access holds `lock`
    typealias Receive = @Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void
    private let lock = NSLock()
    private var sent: [[String: Any]] = []
    private var waiting: Receive?
    private var closedWith: URLSessionWebSocketTask.CloseCode?

    var frames: [[String: Any]] { lock.withLock { sent } }
    var closed: Bool { lock.withLock { closedWith != nil } }

    func resume() {}

    func send(text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let frame = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? ["unparsed": text]
        lock.withLock { sent.append(frame) }
        completion(nil)
    }

    func receive(completion: @escaping Receive) { lock.withLock { waiting = completion } }
    func ping(completion: @escaping @Sendable ((any Error)?) -> Void) { completion(nil) }
    func close(_ code: URLSessionWebSocketTask.CloseCode) { lock.withLock { closedWith = code } }
    var closeReason: Data? { nil }

    /// The server sends one message (the session is waiting for it: it always re-arms `receive`).
    func deliver(_ json: String) {
        let pending = lock.withLock { () -> Receive? in defer { waiting = nil }; return waiting }
        pending?(.success(.string(json)))
    }
}

/// What a frame carries from the microphone, on any wire: audio, an utterance's start (Local's `input.begin`), a
/// turn committed (`input_audio_buffer.commit`, `input.commit`), or the stream ended so the turn is answered
/// (Gemini's `audioStreamEnd`). Anything else (setup, replies, `clear`) is not mic input.
enum MicFrame: Equatable, CustomStringConvertible {
    case audio(String), start, commit, end

    init?(_ frame: [String: Any]) {
        switch frame["type"] as? String {
        case "input_audio_buffer.append", "input.append":
            self = .audio(Self.marker(frame["audio"]))
            return
        case "input.begin":
            self = .start
            return
        case "input_audio_buffer.commit", "input.commit":
            self = .commit
            return
        default:
            break
        }
        guard let input = frame["realtimeInput"] as? [String: Any] else { return nil }
        if let audio = input["audio"] as? [String: Any] {
            self = .audio(Self.marker(audio["data"]))
        } else if input["audioStreamEnd"] != nil {
            self = .end
        } else {
            return nil
        }
    }

    /// The rig's chunks are base64 of a readable label ("muted#41"), so a test can tell whose audio left.
    private static func marker(_ value: Any?) -> String {
        guard let b64 = value as? String, let data = Data(base64Encoded: b64) else { return "?" }
        return String(decoding: data, as: UTF8.self)
    }

    var description: String {
        switch self {
        case .audio(let label): "audio(\(label))"
        case .start: "start"
        case .commit: "commit"
        case .end: "end"
        }
    }
}

/// The rig's speech sensor, standing in for Apple's sound classifier: speech is what a test feeds as speech (chunks
/// tagged `speech…`, loud and above her echo) and nothing else, however loud (noise, a click, her own voice).
final class TagSensor: SpeechSensor, @unchecked Sendable { // every access holds `lock`
    private let lock = NSLock()
    private var speaking = false

    func hear(_ chunk: String, aboveEcho: Bool, loud: Bool) -> Bool? {
        let tag = Data(base64Encoded: chunk).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let speech = tag.hasPrefix("speech") && loud && aboveEcho
        return lock.withLock {
            guard speech != speaking else { return nil }
            speaking = speech
            return speech
        }
    }

    func reset() { lock.withLock { speaking = false } }
}

/// One `Realtime` session with fake sockets and a made-up microphone: the mic path exactly as the app runs it
/// (`Audio.onMic` → the speech gate → stream, hold or drop), minus the audio engine and the network.
@MainActor final class SessionRig {
    /// Every socket the session opened, oldest first.
    final class Sockets: @unchecked Sendable { // touched on main only
        var all: [FakeSocket] = []
    }

    let session: Realtime
    let provider: Provider
    private let sockets = Sockets()
    private var chunk = 0

    init(_ provider: Provider) {
        // The unstarted engine's voice processing must be left alone (as in the self-test): no input node, no mic.
        setenv("HERDR_VOICE_ECHO_CANCEL", "0", 1)
        self.provider = provider
        let sockets = sockets
        // Local needs its runtime's request to connect at all; the cloud wires build theirs from the key.
        let request = provider == .local ? URLRequest(url: URL(string: "ws://127.0.0.1:9/local")!) : nil
        session = Realtime(provider: provider, key: "test-key", voice: "test", request: request,
                           instructions: "test", greeting: "Hello.", speechSensor: TagSensor(), socket: { _ in
                               let socket = FakeSocket()
                               sockets.all.append(socket)
                               return socket
                           })
        // The gate learns the room before it can open (SpeechGate.warmupChunks).
        quiet(30, "warmup")
    }

    var opened: Int { sockets.all.count }
    var socket: FakeSocket? { sockets.all.last }
    /// Every frame sent so far, on every socket, in order.
    var frames: [[String: Any]] { sockets.all.flatMap(\.frames) }
    /// A point in the conversation, to look at what left after it.
    var mark: Int { frames.count }

    func micFrames(since mark: Int) -> [MicFrame] { frames.dropFirst(mark).compactMap(MicFrame.init) }
    func types(since mark: Int) -> [String] { frames.dropFirst(mark).compactMap { $0["type"] as? String } }

    /// The provider answers the setup: the session is up (each wire's first event, or its handshake).
    func serverUp() async {
        let ready = switch provider {
        case .local: #"{"type":"session.updated"}"#
        case .gemini: #"{"setupComplete":{}}"#
        case .openai, .grok: #"{"type":"session.created"}"#
        }
        socket?.deliver(ready)
        await settle()
    }

    func serverSays(_ json: String) async {
        socket?.deliver(json)
        await settle()
    }

    /// 20 ms chunks as the mic queue hands them over, labelled `tag#n`.
    func quiet(_ count: Int, _ tag: String) { feed(count, level: 0.0001, tag) }
    func loud(_ count: Int, _ tag: String) { feed(count, level: 0.1, tag) }

    /// A short sentence: an onset, half a second of speech, and the silence that ends it.
    func say(_ tag: String) async {
        loud(25, tag)
        quiet(60, tag)
        await settle()
    }

    private func feed(_ count: Int, level: Float, _ tag: String) {
        for _ in 0..<count {
            chunk += 1
            session.audio.onMic?(Data("\(tag)#\(chunk)".utf8).base64EncodedString(), level)
        }
    }

    /// Lets what the mic path and the socket queued for main run (wake, speech events, server events).
    func settle() async {
        for _ in 0..<4 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { done.resume() }
            }
        }
    }
}
