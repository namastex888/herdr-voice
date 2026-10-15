import Foundation
@testable import HerdrVoiceCore

/// A flag a test flips while code under test reads it on any thread.
final class Flag: @unchecked Sendable { // `value` is read and written under `lock`
    private let lock = NSLock()
    private var on: Bool

    init(_ on: Bool) { self.on = on }

    var value: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

struct HarnessCall: Equatable {
    let name: String
    let arguments: String
    let user: Bool
}

/// A harness that records calls. `quit_app` needs a spoken yes unless the user asked; `fail_app` always errors.
struct FakeHarness: Harness {
    let id: String
    let title: String
    let names: [String]
    var available = Flag(true)
    var calls = Recorder<HarnessCall>()
    var gate = ConfirmGate(minDelay: 0, wait: 0.2)

    var isAvailable: Bool { available.value }
    var actions: ToolList {
        ToolList(names.map { HerdrTools.fn($0, "does " + $0.replacingOccurrences(of: "_", with: " "), [:], []) })
    }

    func call(_ name: String, arguments: String, userInitiated: Bool) -> HerdrTools.Outcome {
        if name == "quit_app", !userInitiated,
           let stop = HerdrTools.confirmStep(name, action: name, question: "quit", confirmed: false, gate) {
            return HerdrTools.Outcome(output: stop, watch: nil)
        }
        calls.append(HarnessCall(name: name, arguments: arguments, user: userInitiated))
        return HerdrTools.Outcome(output: name == "fail_app" ? "error: it failed" : "done \(name)", watch: nil)
    }
}

/// Fake `mac`, `herdr` and `shell` harnesses sharing one call recorder, and a `broken` one whose factory throws.
/// `made` counts every harness the factory makes, by name.
struct FakeHarnesses: Sendable {
    static let macActions = ["open_app", "quit_app", "set_volume", "list_apps", "fail_app"]
    static let herdrActions = ["list_agents", "prompt_agent", "close_pane"]

    let calls = Recorder<HarnessCall>()
    let made = Recorder<String>()
    let herdrAvailable = Flag(true)
    let gate = ConfirmGate(minDelay: 0, wait: 0.2)

    var factory: HarnessFactory {
        let calls = calls, made = made, herdrAvailable = herdrAvailable, gate = gate
        return HarnessFactory { name, config in
            made.append(name)
            switch name {
            case "mac":
                let extra = config["appleScript"]?.bool == true ? ["run_applescript"] : []
                return FakeHarness(id: "mac", title: "Mac", names: Self.macActions + extra, calls: calls, gate: gate)
            case "herdr":
                return FakeHarness(id: "herdr", title: "Herdr", names: Self.herdrActions, available: herdrAvailable,
                                   calls: calls, gate: gate)
            case "shell":
                return FakeHarness(id: "shell", title: "Shell", names: ["run_shell"], calls: calls, gate: gate)
            case "broken":
                throw ComponentError("this harness always breaks")
            default:
                throw ComponentError("there is no harness called \(name)")
            }
        }
    }
}

func tempDirectory(_ name: String = "companion") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
}

/// A UserDefaults suite of its own, empty unless the test fills it; `cleanUp` removes it.
func scratchDefaults() -> (UserDefaults, cleanUp: () -> Void) {
    let name = "herdr-voice-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (defaults, { defaults.removePersistentDomain(forName: name) })
}

func argumentsJSON(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

func skillEntry(_ id: String, title: String? = nil, summary: String = "s", needs: [String] = ["mac"],
                steps: [String] = ["open_app"], playbook: String = "") -> ConfigEntry {
    Skill(id: id, title: title ?? id, summary: summary, needs: needs, steps: steps.map { Skill.Step(action: $0) },
          playbook: playbook).entry
}

extension SkillRegistry {
    /// Calls a tool the way the voice does, on the user's word unless told otherwise.
    func run(_ name: String, _ arguments: [String: Any] = [:], user: Bool = true) -> String {
        call(name, arguments: argumentsJSON(arguments), userInitiated: user).output
    }
}

/// A seedable generator, so random property runs repeat exactly.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
