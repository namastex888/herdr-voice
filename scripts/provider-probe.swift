// provider-probe PLAN.json: the live half of scripts/provider-contract, for one provider and with no audio.
//
// The plan comes from `herdr-voice providers contract`, so every message is the one the app really sends. The probe
// connects, sends each step's messages in turn and waits for the provider to acknowledge (`session.updated`, Gemini's
// `setupComplete`) or refuse (an error event, or a closed socket) them. Where the acknowledgement echoes the session,
// the tool names and instructions must match what was sent. A step without messages is one the wire doesn't support.
//
// Prints one tab-separated line per step (provider, step, PASS|FAIL|n/a|SKIP, detail); exits 1 if any step failed.
// The key is read from the Keychain here and never printed: no URL or header is printed, and every detail is redacted.
import Foundation

struct Step {
    let name: String
    let messages: [[String: Any]]
    let tools: [String]?
    let instructions: String?
}

struct Plan {
    let provider: String
    let keychainService: String
    let url: URL
    let auth: [String: String]
    let steps: [Step]

    init(_ path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = object["provider"] as? String, let service = object["keychainService"] as? String,
              let url = (object["url"] as? String).flatMap(URL.init(string:)), let auth = object["auth"] as? [String: String],
              let steps = object["steps"] as? [[String: Any]]
        else { throw CocoaError(.fileReadCorruptFile) }
        self.provider = provider
        self.keychainService = service
        self.url = url
        self.auth = auth
        self.steps = steps.map {
            Step(name: $0["name"] as? String ?? "?", messages: $0["messages"] as? [[String: Any]] ?? [],
                 tools: $0["tools"] as? [String], instructions: $0["instructions"] as? String)
        }
    }
}

func keychainPassword(service: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", service, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return p.terminationStatus == 0 && !value.isEmpty ? value : nil
}

/// The connection request, authenticated as the plan says: a header (`{key}` in its value) or a query parameter.
func request(_ plan: Plan, key: String) -> URLRequest {
    if let name = plan.auth["query"], var components = URLComponents(url: plan.url, resolvingAgainstBaseURL: false) {
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: name, value: key)]
        return URLRequest(url: components.url ?? plan.url)
    }
    var request = URLRequest(url: plan.url)
    if let header = plan.auth["header"], let value = plan.auth["value"] {
        request.setValue(value.replacingOccurrences(of: "{key}", with: key), forHTTPHeaderField: header)
    }
    return request
}

@MainActor final class Probe {
    static let ackTimeout: TimeInterval = 20
    /// After the last acknowledgement, how long a late refusal still counts.
    static let grace: TimeInterval = 2

    private let plan: Plan
    private let key: String
    private let task: URLSessionWebSocketTask
    private var index = -1
    private var waiting = false
    private var timer: DispatchWorkItem?
    private var lines: [String] = []
    private var failed = false
    private var finished = false

    init(plan: Plan, key: String) {
        self.plan = plan
        self.key = key
        task = URLSession.shared.webSocketTask(with: request(plan, key: key))
    }

    func start() {
        task.resume()
        receive()
        next()
    }

    private func redact(_ text: String) -> String {
        text.replacingOccurrences(of: key, with: "<key>").replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func record(_ step: String, _ status: String, _ detail: String) {
        if status == "FAIL" { failed = true }
        lines.append([plan.provider, step, status, redact(detail)].joined(separator: "\t"))
    }

    private func arm(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        timer?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func next() {
        index += 1
        guard index < plan.steps.count else {
            waiting = false
            return arm(Self.grace) { self.finish() }
        }
        let step = plan.steps[index]
        guard !step.messages.isEmpty else {
            record(step.name, "n/a", "the wire doesn't support it (see docs/providers.md)")
            return next()
        }
        waiting = true
        for message in step.messages {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else {
                return fail("message isn't JSON")
            }
            task.send(.string(String(decoding: data, as: UTF8.self))) { error in
                guard let error else { return }
                let code = (error as NSError).code
                Task { @MainActor in self.fail("send failed (\((error as NSError).domain) \(code))") }
            }
        }
        arm(Self.ackTimeout) { self.fail("no acknowledgement within \(Int(Self.ackTimeout)) s") }
    }

    /// The current step (or, after the last one, the last step) failed; the rest are not attempted.
    private func fail(_ detail: String) {
        guard !finished else { return }
        let current = min(max(index, 0), plan.steps.count - 1)
        record(plan.steps[current].name, "FAIL", detail)
        for step in plan.steps.dropFirst(current + 1) { record(step.name, "FAIL", "not attempted") }
        index = plan.steps.count
        finish()
    }

    private func receive() {
        task.receive { result in
            Task { @MainActor in
                switch result {
                case .success(.string(let text)): self.received(text)
                case .success(.data(let data)): self.received(String(decoding: data, as: UTF8.self)) // Gemini: binary frames
                case .success: break
                case .failure(let error):
                    let reason = self.task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    let code = self.task.closeCode.rawValue
                    self.fail("connection closed (\((error as NSError).domain) \((error as NSError).code), close \(code)"
                        + (reason.isEmpty ? ")" : ": \(reason))"))
                    return
                }
                if !self.finished { self.receive() }
            }
        }
    }

    private func received(_ text: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        let type = object["type"] as? String
        if type == "error" || object["error"] != nil {
            let error = object["error"] as? [String: Any]
            return fail("refused: \(error?["message"] as? String ?? text.prefix(300).description)")
        }
        guard waiting, index < plan.steps.count else { return }
        let ack = type == "session.updated" ? "session.updated" : object["setupComplete"] != nil ? "setupComplete" : nil
        guard let ack else { return }
        let step = plan.steps[index]
        var detail = "acknowledged (\(ack))"
        if let session = object["session"] as? [String: Any] {
            if let sent = step.tools, let echoed = session["tools"] as? [[String: Any]] {
                // OpenAI echoes `{name, ...}`; xAI echoes `{type: function, function: {name, ...}}`. Built-in tools
                // (web search) have no name either way.
                let names = echoed.compactMap {
                    $0["name"] as? String ?? ($0["function"] as? [String: Any])?["name"] as? String
                }
                guard Set(names) == Set(sent) else {
                    let missing = Set(sent).subtracting(names).sorted().prefix(5).joined(separator: ", ")
                    let shape = Set(echoed.flatMap(\.keys)).sorted().joined(separator: ",")
                    return fail("the session kept \(names.count) of \(sent.count) tools (missing: \(missing); "
                        + "echoed tools have keys \(shape))")
                }
                detail += ", \(names.count) tools echoed"
            }
            if let sent = step.instructions, let echoed = session["instructions"] as? String {
                guard echoed == sent else { return fail("the session's instructions differ from those sent") }
                detail += ", instructions echoed"
            }
        }
        record(step.name, "PASS", detail)
        waiting = false
        next()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        lines.forEach { print($0) }
        exit(failed ? 1 : 0)
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 2, let plan = try? Plan(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: provider-probe PLAN.json (from herdr-voice providers contract)\n".utf8))
    exit(2)
}
guard let key = keychainPassword(service: plan.keychainService) else {
    for step in plan.steps { print([plan.provider, step.name, "SKIP", "no \(plan.keychainService) in the Keychain"].joined(separator: "\t")) }
    exit(0)
}
let probe = Probe(plan: plan, key: key)
probe.start()
dispatchMain()
