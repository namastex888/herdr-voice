import AVFoundation
import HerdrVoiceCore
import Speech
import VoiceEngine

/// The current recognition request: appended to from the mic queue, replaced on main. A request takes buffers from
/// any thread; the lock only guards which request is current.
private final class RequestSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ next: SFSpeechAudioBufferRecognitionRequest?) { lock.withLock { request = next } }
    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { request?.append(buffer) } }
}

/// Listens for the wake phrase with Apple's speech recognizer, on this Mac only (`requiresOnDeviceRecognition`), fed
/// from the mic buffers the session already captures (`Audio.setMicTap`), not a second audio engine. Nothing it
/// hears leaves the Mac. It listens only between conversations; a match starts one like a tap of the key.
@MainActor final class WakeWordSpotter {
    enum Status: Equatable {
        case off
        case listening
        /// Why it can't listen; the companion falls back to tap-to-talk and says so.
        case unavailable(String)
    }

    private(set) var status = Status.off
    var phrase: String {
        didSet { if phrase != oldValue, status == .listening { beginTask() } }
    }
    private let onWake: () -> Void
    private var recognizer: SFSpeechRecognizer?
    private weak var audio: Audio?
    private let request = RequestSlot()
    private var task: SFSpeechRecognitionTask?
    /// Bumped per task, so a cancelled task's last callback isn't taken for the current one's.
    private var generation = 0
    private var renewTimer: Timer?
    private var lastWake = Date.distantPast
    /// Paused while a conversation is on: the session is listening then, and two listeners would both hear you.
    private var paused = false

    /// Recognition tasks wind down after about a minute; a fresh one well before that keeps it listening.
    static let renewInterval: TimeInterval = 50
    /// A phrase heard again this soon is the same one, still in the transcript.
    static let rearm: TimeInterval = 2

    init(phrase: String, onWake: @escaping () -> Void) {
        self.phrase = phrase
        self.onWake = onWake
    }

    /// The app bundle declares why it wants speech recognition. Asking without it would end the process, so a bare
    /// build (`swift run`, the self-test) never asks.
    static var canAsk: Bool { Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil }

    /// Asks for permission if needed and starts listening; `done` gets the outcome.
    func start(audio: Audio, done: @escaping (Status) -> Void) {
        guard status != .listening else { return done(status) }
        guard Self.canAsk else { return done(fail("wake word needs the installed app (speech permission)")) }
        let finish = { (authorized: Bool) in
            guard authorized else {
                return done(self.fail("speech recognition isn't allowed (System Settings → Privacy & Security)"))
            }
            done(self.listen(audio: audio))
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: finish(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { auth in
                DispatchQueue.main.async { finish(auth == .authorized) }
            }
        default: finish(false)
        }
    }

    func stop() {
        renewTimer?.invalidate()
        renewTimer = nil
        task?.cancel()
        task = nil
        request.set(nil)
        audio?.setMicTap(nil)
        if status == .listening { status = .off }
    }

    /// Off during a conversation, on again after it.
    func setPaused(_ on: Bool) {
        guard on != paused else { return }
        paused = on
        guard status == .listening else { return }
        if on {
            task?.cancel()
            task = nil
            request.set(nil)
        } else {
            beginTask()
        }
    }

    private func fail(_ why: String) -> Status {
        stop()
        status = .unavailable(why)
        return status
    }

    private func listen(audio: Audio) -> Status {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            return fail("on-device speech recognition isn't available on this Mac")
        }
        self.recognizer = recognizer
        self.audio = audio
        let request = request
        audio.setMicTap { buffer in request.append(buffer) }
        status = .listening
        renewTimer = Timer.scheduledTimer(withTimeInterval: Self.renewInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.paused == false { self?.beginTask() } }
        }
        if !paused { beginTask() }
        return status
    }

    private func beginTask() {
        task?.cancel()
        guard let recognizer, !paused else { return }
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.requiresOnDeviceRecognition = true
        next.shouldReportPartialResults = true
        next.contextualStrings = [phrase]
        request.set(next)
        generation += 1
        let current = generation
        task = recognizer.recognitionTask(with: next) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString ?? ""
            let ended = (result?.isFinal ?? false) || error != nil
            DispatchQueue.main.async { self?.heard(text, ended: ended, generation: current) }
        }
    }

    private func heard(_ text: String, ended: Bool, generation: Int) {
        guard generation == self.generation, status == .listening, !paused else { return }
        if WakePhrase.matches(text, phrase: phrase), Date().timeIntervalSince(lastWake) > Self.rearm {
            lastWake = Date()
            beginTask() // a clean transcript, so the phrase isn't heard twice
            onWake()
            return
        }
        // The recognizer gave up (silence, an error): listen again in a moment rather than spin.
        if ended {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.status == .listening, !self.paused else { return }
                self.beginTask()
            }
        }
    }
}
