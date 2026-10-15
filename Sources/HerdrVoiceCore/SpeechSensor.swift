import Foundation

/// Tells someone talking apart from everything else the mic hears, for barge-in and turn-taking. It never decides
/// what is streamed (the gate does). The provider's speech detection hears noise and her own echo as speech too,
/// so its "speech started" only cuts her off, or counts as your turn, once a sensor agrees the mic hears speech.
public protocol SpeechSensor: AnyObject, Sendable {
    /// On the mic queue, every 20 ms: one chunk (base64 PCM16, 24 kHz mono). `aboveEcho`: louder than her own voice's
    /// echo (`EchoGuard`); a chunk that isn't is silence as far as speech goes. `loud`: speech-loud by the gate's
    /// measure. Returns true when speech starts, false when it stops, nil when nothing changed.
    func hear(_ chunk: String, aboveEcho: Bool, loud: Bool) -> Bool?
    /// Forgets what it heard (the mic went off): the next speech starts afresh.
    func reset()
}

/// The sensor where Apple's sound classifier isn't used: the gate's own rules, on the echo-guarded level. Speech
/// starts after `SpeechGate.onsetChunks` speech-loud chunks in a row and stops after `SpeechGate.hangoverChunks`
/// without one.
public final class LoudnessSensor: SpeechSensor, @unchecked Sendable { // every access holds `lock`
    private let lock = NSLock()
    private var loudRun = 0
    private var quietRun = 0
    private var speaking = false

    public init() {}

    public func hear(_ chunk: String, aboveEcho: Bool, loud: Bool) -> Bool? {
        lock.withLock {
            if loud && aboveEcho {
                loudRun += 1
                quietRun = 0
            } else {
                loudRun = 0
                quietRun += 1
            }
            if !speaking, loudRun >= SpeechGate<String>.onsetChunks {
                speaking = true
                return true
            }
            if speaking, quietRun >= SpeechGate<String>.hangoverChunks {
                speaking = false
                return false
            }
            return nil
        }
    }

    public func reset() {
        lock.withLock {
            loudRun = 0
            quietRun = 0
            speaking = false
        }
    }
}
