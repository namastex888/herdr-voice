import Foundation
import os

/// Opt-in `run_shell` tool. Off unless HERDR_VOICE_SHELL=1. A read-only check the user asked for runs at once;
/// anything else needs the user's spoken yes bound to that exact command and directory, so neither the model nor
/// injected terminal text can change anything. Code decides what is read-only (`isReadOnly`), never the model.
extension HerdrTools {
    public static var shellEnabled: Bool { ProcessInfo.processInfo.environment["HERDR_VOICE_SHELL"] == "1" }
    public static let shellTimeout: TimeInterval = 60
    static let shellOutputLimit = 4000

    nonisolated(unsafe) static let shellSchema = fn(
        "run_shell",
        "Run a short shell command (zsh, no input, 60 s limit) and get its exit code and output. For quick checks the "
            + "developer asks for; send real coding work to an agent with prompt_agent instead. Read-only checks "
            + "(listing files, git status, branch or log) run at once. Anything that changes something answers "
            + "CONFIRMATION REQUIRED: ask in plain words, then call again with confirmed=true after they say yes.",
        ["command": str("The exact shell command"),
         "cwd": str("Directory to run in, e.g. an agent's cwd. Defaults to herdr-voice's directory"),
         "confirmed": confirmedField],
        ["command"])

    public struct ShellResult: Equatable, Sendable {
        public let status: Int32
        public let output: String
        public let timedOut: Bool
    }

    public typealias ShellExec = @Sendable (_ command: String, _ cwd: String, _ timeout: TimeInterval) -> ShellResult

    static func runShell(_ command: String, cwd: String?, confirmed: Bool, _ gate: ConfirmGate,
                         userInitiated: Bool = true, exec: ShellExec = shellExec) -> String {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return "error: no command" }
        let dir = NSString(string: cwd ?? FileManager.default.currentDirectoryPath).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return "error: \(dir) is not a directory"
        }
        // A read-only check the user asked for runs at once; one prompted by an agent report or tool output asks.
        if !(userInitiated && isReadOnly(command)),
           let stop = confirmStep("run_shell", action: "run_shell:\(dir):\(command)",
                                  question: "run this command in the \((dir as NSString).lastPathComponent) folder: \(command)",
                                  confirmed: confirmed, gate) {
            return stop
        }
        let r = exec(command, dir, shellTimeout)
        let head = r.timedOut ? "timed out after \(Int(shellTimeout)) s and was stopped" : "exit \(r.status)"
        return head + "\n" + untrusted(r.output.isEmpty ? "(no output)" : r.output)
    }

    /// Programs that only read, and the git subcommands that only read. Anything that prints file contents or the
    /// environment (cat, head, env) stays off: the output goes to the voice provider, so it could leak secrets.
    static let readOnlyPrograms: Set<String> = ["ls", "pwd", "whoami", "date", "uname", "which", "wc", "du", "df"]
    static let readOnlyGit: Set<String> = ["status", "branch", "log", "diff", "show", "rev-parse"]
    /// Long git flags that make an otherwise read-only subcommand write (delete, rename, write a file, run a tool).
    static let writingGitFlags: Set<String> = ["--delete", "--move", "--copy", "--force", "--output",
                                               "--set-upstream-to", "--unset-upstream", "--edit-description",
                                               "--ext-diff", "--textconv"]
    /// Short git flags that write, alone or bundled ("-dr"): delete, move, copy, force, set upstream.
    static let writingGitShortFlags = Set("dDmMcCfu")

    /// True only for one allowlisted read-only command with no shell syntax. Anything unknown asks.
    static func isReadOnly(_ command: String) -> Bool {
        // No chaining, pipes, redirects, substitution, globs, quoting, variables or `--flag=value`.
        guard command.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|<>$`(){}[]*?!~\\\"'#=\n\r")) == nil
        else { return false }
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let program = words.first else { return false }
        if readOnlyPrograms.contains(program) { return true }
        guard program == "git", words.count >= 2, readOnlyGit.contains(words[1]) else { return false }
        let rest = words.dropFirst(2)
        // `git branch <name>` creates a branch; with only flags it lists them.
        if words[1] == "branch", rest.contains(where: { !$0.hasPrefix("-") }) { return false }
        return !rest.contains { word in
            if word.hasPrefix("--") { return writingGitFlags.contains(word) }
            return word.hasPrefix("-") && word.dropFirst().contains(where: writingGitShortFlags.contains)
        }
    }

    /// zsh -c with stdin closed and stdout+stderr merged. Keeps only the last `shellOutputLimit` characters.
    public static let shellExec: ShellExec = { command, cwd, timeout in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return ShellResult(status: -1, output: "failed to start: \(error)", timedOut: false) }

        // Drain concurrently so a chatty command can't block on a full pipe; keep a bounded tail. A dedicated
        // thread, not the GCD pool: with its threads blocked (parallel tests) the drain started too late to count.
        let tail = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchSemaphore(value: 0)
        Thread {
            while case let chunk = pipe.fileHandleForReading.availableData, !chunk.isEmpty {
                tail.withLock { tail in
                    tail.append(chunk)
                    if tail.count > 64_000 { tail.removeFirst(tail.count - 64_000) }
                }
            }
            drained.signal()
        }.start()

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL) }
        }
        // ponytail: only zsh is signalled; background children it spawned keep the pipe open and outlive us.
        // Spawn in its own process group (posix_spawn) if that ever matters.
        _ = drained.wait(timeout: .now() + 2)
        let text = tail.withLock { String(decoding: $0, as: UTF8.self) }
        return ShellResult(status: p.isRunning ? -1 : p.terminationStatus,
                           output: String(text.suffix(shellOutputLimit)), timedOut: timedOut)
    }
}
