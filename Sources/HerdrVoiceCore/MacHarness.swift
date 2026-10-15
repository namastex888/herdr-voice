import AppKit
import Foundation
import os

/// The Mac itself, through its stock command-line tools (`open`, `osascript`, `pbcopy`, `shortcuts`, `pmset`), so it
/// needs no Accessibility permission. The developer's words reach those tools only as argv entries, never through a
/// shell, and any that go into AppleScript are escaped string literals.
public struct MacHarness: Harness {
    /// Runs `executable` with `arguments`, feeding `stdin` when given. Returns the exit status and stdout+stderr.
    public typealias Exec = @Sendable (_ executable: String, _ arguments: [String], _ stdin: String?)
        -> (status: Int32, output: String)
    public typealias RunningApps = @Sendable () -> [RunningApp]

    public struct RunningApp: Equatable, Sendable {
        public let name: String
        public let bundleID: String?
        public let isFrontmost: Bool

        public init(name: String, bundleID: String? = nil, isFrontmost: Bool = false) {
            self.name = name
            self.bundleID = bundleID
            self.isFrontmost = isFrontmost
        }
    }

    public static let timeout: TimeInterval = 15
    static let outputLimit = 4000

    private let allowAppleScript: Bool
    private let gate: ConfirmGate
    private let exec: Exec
    private let runningApps: RunningApps

    public init(allowAppleScript: Bool = false, gate: ConfirmGate = .shared, exec: @escaping Exec = MacHarness.defaultExec,
                runningApps: @escaping RunningApps = MacHarness.dockApps) {
        self.allowAppleScript = allowAppleScript
        self.gate = gate
        self.exec = exec
        self.runningApps = runningApps
    }

    public var id: String { "mac" }
    public var title: String { "Mac" }
    public var isAvailable: Bool { true }
    public var actions: ToolList { ToolList(Self.schemas + (allowAppleScript ? [Self.appleScriptSchema] : [])) }

    public func call(_ name: String, arguments: String, userInitiated: Bool) -> HerdrTools.Outcome {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        return HerdrTools.Outcome(output: run(name, args, userInitiated: userInitiated), watch: nil)
    }

    // MARK: schemas

    static let askAgain = "If it answers CONFIRMATION REQUIRED, ask the developer and call again with confirmed=true after they say yes."

    nonisolated(unsafe) static let schemas: [[String: Any]] = {
        let fn = HerdrTools.fn, str = HerdrTools.str, confirmed = HerdrTools.confirmedField
        return [
            fn("open_app", "Open an app on the Mac, or bring it to the front if it is already open, e.g. Safari or Notes.",
               ["name": str("The app's name, e.g. Safari")], ["name"]),
            fn("quit_app", "Quit an app that is open on the Mac; it may ask to save open documents first. " + askAgain,
               ["name": str("The app's name as list_apps shows it"), "confirmed": confirmed], ["name"]),
            fn("list_apps", "List the apps open on the Mac (the ones in the Dock) and which one is in front.", [:], []),
            fn("open_url", "Open a web page (http or https) in the default browser, or a mailto: link as a new email draft.",
               ["url": str("The full link, starting with https://, http:// or mailto:")], ["url"]),
            fn("open_path", "Open a file or folder on the Mac with its default app, or show it in Finder. " + askAgain,
               ["path": str("Full path; ~ is the home folder, e.g. ~/Downloads"),
                "reveal": ["type": "boolean", "description": "Show it selected in Finder instead of opening it; default false"],
                "confirmed": confirmed],
               ["path"]),
            fn("get_volume", "Get the Mac's sound volume (0 to 100) and whether it is muted.", [:], []),
            fn("set_volume", "Set the Mac's sound volume.",
               ["percent": ["type": "integer", "description": "Volume from 0 to 100"]], ["percent"]),
            fn("mute", "Mute or unmute the Mac's sound.",
               ["muted": ["type": "boolean", "description": "true to mute, false to unmute"]], ["muted"]),
            fn("set_dark_mode", "Turn the Mac's dark mode on or off, or switch to the other appearance.",
               ["mode": ["type": "string", "enum": ["on", "off", "toggle"], "description": "on, off, or toggle to switch"]],
               ["mode"]),
            fn("read_clipboard", "Read the text on the Mac's clipboard.", [:], []),
            fn("write_clipboard", "Put text on the Mac's clipboard, replacing what was there.",
               ["text": str("The text to copy")], ["text"]),
            fn("notify", "Show a notification on the Mac's screen.",
               ["title": str("Short title"), "message": str("The notification text")], ["title", "message"]),
            fn("list_shortcuts", "List the developer's shortcuts from the Shortcuts app, by name.", [:], []),
            fn("run_shortcut", "Run one of the developer's shortcuts by name, optionally with text input, and get its output "
               + "(15 s limit). " + askAgain,
               ["name": str("The shortcut's name as list_shortcuts shows it"), "input": str("Text to pass in, if it takes input"),
                "confirmed": confirmed],
               ["name"]),
            fn("battery", "Get the Mac's battery level, whether it is charging, and the time left.", [:], []),
            fn("sleep_display", "Turn the Mac's display off now; that may lock the screen. " + askAgain,
               ["confirmed": confirmed], []),
        ]
    }()

    nonisolated(unsafe) static let appleScriptSchema = HerdrTools.fn(
        "run_applescript",
        "Run a short AppleScript on the Mac (15 s limit) and get its result, for Mac tasks the other tools don't cover. "
            + "Always two calls: call without confirmed, ask the developer, then call again with confirmed=true after they say yes.",
        ["script": HerdrTools.str("The exact AppleScript source"), "confirmed": HerdrTools.confirmedField],
        ["script"])

    // MARK: actions

    static let open = "/usr/bin/open", osascript = "/usr/bin/osascript", pbcopy = "/usr/bin/pbcopy",
               pbpaste = "/usr/bin/pbpaste", shortcuts = "/usr/bin/shortcuts", pmset = "/usr/bin/pmset"

    private func run(_ tool: String, _ args: [String: Any], userInitiated: Bool) -> String {
        func text(_ key: String) -> String? {
            (args[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let confirmed = args["confirmed"] as? Bool ?? false
        // A spoken yes, needed only when the model acts on a report rather than on the developer's words.
        func ask(_ action: String, _ question: String) -> String? {
            userInitiated ? nil
                : HerdrTools.confirmStep(tool, action: "\(tool):\(action)", question: question, confirmed: confirmed, gate)
        }
        let q = Self.appleScriptLiteral

        switch tool {
        case "open_app":
            guard let name = text("name") else { return "error: say which app" }
            return done(exec(Self.open, ["-a", name], nil), "opened \(name)")

        case "quit_app":
            guard let name = text("name") else { return "error: say which app" }
            let apps = runningApps()
            // `tell application` launches an app that isn't running, so only running ones are quit.
            guard let app = Self.match(name, in: apps) else {
                return "error: no open app is called \(name); open apps: " + apps.map(\.name).sorted().joined(separator: ", ")
            }
            if let stop = ask(app.bundleID ?? app.name, "quit \(app.name)") { return stop }
            // By bundle id when there is one: the Dock name ("Code", or a localized one) isn't always AppleScript's.
            let target = app.bundleID.map { "application id \(q($0))" } ?? "application \(q(app.name))"
            return done(exec(Self.osascript, ["-e", "tell \(target) to quit"], nil), "quit \(app.name)")

        case "list_apps":
            let apps = runningApps().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !apps.isEmpty else { return "no apps are open" }
            let front = apps.first(where: \.isFrontmost).map { "in front: \($0.name)\n" } ?? ""
            return front + "open: " + apps.map(\.name).joined(separator: ", ")

        case "open_url":
            guard let raw = text("url") else { return "error: say which link" }
            switch Self.webURL(raw) {
            case .failure(let e): return e.text
            case .success(let url): return done(exec(Self.open, [url], nil), "opened \(url)")
            }

        case "open_path":
            guard let raw = text("path") else { return "error: say which file or folder" }
            let path = NSString(string: raw).expandingTildeInPath
            guard path.hasPrefix("/") else { return "error: give the full path to \(raw), e.g. ~/Documents/\(raw)" }
            guard FileManager.default.fileExists(atPath: path) else { return "error: \(path) does not exist" }
            if args["reveal"] as? Bool == true { return done(exec(Self.open, ["-R", path], nil), "showed \(path) in Finder") }
            // Opening an app or an executable file runs it, so an unprompted open needs a yes; revealing is harmless.
            if let stop = ask(path, "open \(path)") { return stop }
            return done(exec(Self.open, [path], nil), "opened \(path)")

        case "get_volume":
            let r = exec(Self.osascript, ["-e", "set s to get volume settings", "-e", "return {output volume of s, output muted of s}"], nil)
            return r.status == 0 ? Self.volumeText(r.output) : Self.failure(r)

        case "set_volume":
            guard let percent = Self.percent(args["percent"]) else { return "error: percent must be a number from 0 to 100" }
            return done(exec(Self.osascript, ["-e", "set volume output volume \(percent)"], nil), "volume set to \(percent)%")

        case "mute":
            guard let muted = args["muted"] as? Bool else { return "error: say whether to mute (true) or unmute (false)" }
            return done(exec(Self.osascript, ["-e", "set volume output muted \(muted)"], nil), muted ? "muted" : "unmuted")

        case "set_dark_mode":
            let value: String
            switch text("mode")?.lowercased() {
            case "on": value = "true"
            case "off": value = "false"
            case "toggle": value = "not dark mode"
            default: return "error: mode must be on, off or toggle"
            }
            let r = exec(Self.osascript, ["-e", "tell application \"System Events\"", "-e", "tell appearance preferences",
                                          "-e", "set dark mode to \(value)", "-e", "return dark mode",
                                          "-e", "end tell", "-e", "end tell"], nil)
            guard r.status == 0 else { return Self.failure(r) }
            switch Self.trimmed(r.output) {
            case "true": return "done: dark mode is on"
            case "false": return "done: dark mode is off"
            default: return "done: dark mode set"
            }

        case "read_clipboard":
            let r = exec(Self.pbpaste, [], nil)
            guard r.status == 0 else { return Self.failure(r) }
            let clip = Self.trimmed(r.output)
            return clip.isEmpty ? "the clipboard has no text" : HerdrTools.untrusted(Self.limit(clip))

        case "write_clipboard":
            guard let text = args["text"] as? String, !text.isEmpty else { return "error: say what to copy" }
            return done(exec(Self.pbcopy, [], text), "copied \(text.count) characters to the clipboard")

        case "notify":
            guard let message = text("message") else { return "error: say what the notification should say" }
            let script = "display notification \(q(message))" + (text("title").map { " with title \(q($0))" } ?? "")
            return done(exec(Self.osascript, ["-e", script], nil), "notification shown")

        case "list_shortcuts":
            let r = exec(Self.shortcuts, ["list"], nil)
            guard r.status == 0 else { return Self.failure(r) }
            let names = Self.trimmed(r.output)
            return names.isEmpty ? "there are no shortcuts" : Self.limit(names)

        case "run_shortcut":
            return runShortcut(text("name"), input: args["input"] as? String, ask: ask)

        case "battery":
            let r = exec(Self.pmset, ["-g", "batt"], nil)
            return r.status == 0 ? Self.batteryText(r.output) : Self.failure(r)

        case "sleep_display":
            if let stop = ask("now", "turn the display off now") { return stop }
            return done(exec(Self.pmset, ["displaysleepnow"], nil), "the display is off")

        case "run_applescript":
            guard allowAppleScript else { return "error: AppleScript is switched off" }
            guard let script = text("script") else { return "error: no script" }
            // Always asked, like run_shell: the action is the exact script, so a yes can't carry over to another.
            if let stop = HerdrTools.confirmStep(tool, action: "\(tool):\(script)", question: "run this AppleScript: \(script)",
                                                 confirmed: confirmed, gate) {
                return stop
            }
            let r = exec(Self.osascript, ["-e", script], nil)
            let out = Self.trimmed(r.output)
            return "exit \(r.status)\n" + HerdrTools.untrusted(out.isEmpty ? "(no output)" : Self.limit(out))

        default:
            return "error: unknown tool \(tool)"
        }
    }

    private func runShortcut(_ name: String?, input: String?, ask: (String, String) -> String?) -> String {
        guard let name else { return "error: say which shortcut" }
        let input = input.flatMap { $0.isEmpty ? nil : $0 }
        if let stop = ask("\(name)\n\(input ?? "")", "run the shortcut \(name)" + (input.map { " with the input \($0)" } ?? "")) {
            return stop
        }
        // The CLI takes input only as a file. `--` ends the options, so a name can't pass as one.
        var arguments = ["run"]
        var file: URL?
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        if let input {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-voice-\(UUID().uuidString).txt")
            do { try Data(input.utf8).write(to: url) } catch { return "error: could not pass the input: \(error.localizedDescription)" }
            file = url
            arguments += ["--input-path", url.path]
        }
        let r = exec(Self.shortcuts, arguments + ["--", name], nil)
        let out = Self.trimmed(r.output)
        // A shortcut can fetch anything, so even its error text is fenced.
        guard r.status == 0 else { return "error: \(name) failed (exit \(r.status))\n" + HerdrTools.untrusted(Self.limit(out)) }
        return "done: ran \(name)" + (out.isEmpty ? "" : "\n" + HerdrTools.untrusted(Self.limit(out)))
    }

    private func done(_ r: (status: Int32, output: String), _ what: String) -> String {
        r.status == 0 ? "done: \(what)" : Self.failure(r)
    }

    // MARK: helpers

    static func failure(_ r: (status: Int32, output: String)) -> String {
        let why = trimmed(r.output)
        return "error: " + (why.isEmpty ? "exit \(r.status)" : limit(why))
    }

    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func limit(_ s: String) -> String { s.count > outputLimit ? String(s.prefix(outputLimit)) + "\n(cut)" : s }

    /// `text` as an AppleScript string literal, quotes included. Backslashes first, then double quotes, so user text
    /// can't close the literal and run its own commands. Curly quotes don't end a straight-quoted literal.
    static func appleScriptLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The running app the developer named: same name ignoring case and accents, else the only one containing it.
    static func match(_ name: String, in apps: [RunningApp]) -> RunningApp? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let hit = apps.first(where: { $0.name.compare(name, options: options) == .orderedSame }) { return hit }
        let partial = apps.filter { $0.name.range(of: name, options: options) != nil }
        return partial.count == 1 ? partial[0] : nil
    }

    /// Web pages and email drafts only: `open` hands any other scheme (file:, javascript:, an app's own scheme) to
    /// whatever claims it, which can run code or act inside another app.
    static func webURL(_ raw: String) -> Result<String, Refusal> {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            return .failure(Refusal(text: "error: give the full link, starting with https://, http:// or mailto:"))
        }
        guard ["http", "https", "mailto"].contains(scheme) else {
            return .failure(Refusal(text: "error: only http, https and mailto links can be opened, not \(scheme): links"))
        }
        if scheme != "mailto", url.host?.isEmpty ?? true {
            return .failure(Refusal(text: "error: \(raw) has no web address after \(scheme)://"))
        }
        return .success(url.absoluteString)
    }

    struct Refusal: Error { let text: String }

    /// A volume from the model: a JSON number or a numeric string ("40", "40%"), 0...100, rounded. Never a bool.
    static func percent(_ value: Any?) -> Int? {
        let number: Double?
        switch value {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): number = n.doubleValue
        case let s as String: number = Double(trimmed(s).replacingOccurrences(of: "%", with: ""))
        default: number = nil
        }
        guard let number, (0...100).contains(number) else { return nil }
        return Int(number.rounded())
    }

    /// osascript's "81, false" as "volume 81%"; anything else (an output device without volume control) as is.
    static func volumeText(_ out: String) -> String {
        let parts = trimmed(out).components(separatedBy: ", ")
        guard parts.count == 2, let level = Int(parts[0]) else { return "volume: \(trimmed(out))" }
        return "volume \(level)%" + (parts[1] == "true" ? ", muted" : "")
    }

    /// `pmset -g batt` on one line, e.g. "73%, charging, 5:49 remaining; on AC Power".
    static func batteryText(_ out: String) -> String {
        let lines = out.split(whereSeparator: \.isNewline).map(String.init)
        let source = lines.first?.split(separator: "'", omittingEmptySubsequences: false).dropFirst().first.map { "on \($0)" }
        let battery = lines.dropFirst().first { $0.contains("%") }.map { line in
            (line.split(separator: "\t", maxSplits: 1).last.map(String.init) ?? line)
                .replacingOccurrences(of: "present: true", with: "")
                .split(separator: ";").map { trimmed(String($0)) }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
        switch (battery, source) {
        case let (battery?, source?): return "\(battery); \(source)"
        case let (battery?, nil): return battery
        case let (nil, source?): return "no battery; \(source)"
        case (nil, nil): return trimmed(out)
        }
    }

    // MARK: defaults

    /// Regular apps, the ones with a Dock icon, as NSWorkspace sees them: read-only, and no permission needed.
    public static let dockApps: RunningApps = {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { app in
            app.localizedName.map { RunningApp(name: $0, bundleID: app.bundleIdentifier, isFrontmost: app.isActive) }
        }
    }

    public static let defaultExec: Exec = processExec(timeout: timeout)

    /// Runs a process with stdin closed unless `stdin` is given, stdout+stderr merged, and only the first 64 KB kept.
    /// Stopped after `timeout` seconds.
    public static func processExec(timeout: TimeInterval) -> Exec {
        { executable, arguments, stdin in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            // pbcopy and pbpaste read LANG for the text encoding; an app started from Finder has none.
            var env = ProcessInfo.processInfo.environment
            if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
            p.environment = env
            let input = stdin == nil ? nil : Pipe()
            p.standardInput = input ?? FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe

            let exited = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in exited.signal() }
            do { try p.run() } catch { return (-1, "could not run \(executable): \(error.localizedDescription)") }

            if let input, let stdin {
                // A process that exits without reading must not SIGPIPE us; its own thread, so a full pipe can't block.
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                Thread {
                    try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                    try? input.fileHandleForWriting.close()
                }.start()
            }

            // Drained on a dedicated thread, as in shellExec, so a chatty process can't stall on a full pipe.
            let head = OSAllocatedUnfairLock(initialState: Data())
            let drained = DispatchSemaphore(value: 0)
            Thread {
                while case let chunk = pipe.fileHandleForReading.availableData, !chunk.isEmpty {
                    head.withLock { kept in kept.append(chunk.prefix(max(0, 64_000 - kept.count))) }
                }
                drained.signal()
            }.start()

            var timedOut = false
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                p.terminate()
                if exited.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            }
            _ = drained.wait(timeout: .now() + 2)
            let text = head.withLock { String(decoding: $0, as: UTF8.self) }
            if timedOut { return (-1, text + "\n(timed out after \(Int(timeout)) s and was stopped)") }
            return (p.isRunning ? -1 : p.terminationStatus, text)
        }
    }
}
