import Foundation
import os
import Testing
@testable import HerdrVoiceCore

private func gate() -> ConfirmGate { ConfirmGate(minDelay: 0, wait: 0.2) }

@Test func shellIsOffUnlessEnabled() {
    // The test process doesn't set HERDR_VOICE_SHELL.
    #expect(!HerdrTools.schemas.contains { $0["name"] as? String == "run_shell" })
    #expect(HerdrTools.call("run_shell", arguments: #"{"command":"echo hi"}"#, gate: gate()).output.contains("disabled"))
}

private func recorder() -> (OSAllocatedUnfairLock<[String]>, HerdrTools.ShellExec) {
    let ran = OSAllocatedUnfairLock(initialState: [String]())
    return (ran, { cmd, _, _ in ran.withLock { $0.append(cmd) }; return .init(status: 0, output: "ok", timedOut: false) })
}

@Test func readOnlyChecksRunWithoutAsking() {
    let (ran, exec) = recorder()

    let out = HerdrTools.runShell("ls", cwd: "/tmp", confirmed: false, gate(), exec: exec)
    #expect(out.hasPrefix("exit 0\n<<<UNTRUSTED TERMINAL OUTPUT"))
    _ = HerdrTools.runShell("git status", cwd: "/tmp", confirmed: false, gate(), exec: exec)
    #expect(ran.withLock { $0 } == ["ls", "git status"])

    // Prompted by an agent report or tool output rather than the user's voice: still asks, even for ls.
    #expect(HerdrTools.runShell("ls", cwd: "/tmp", confirmed: false, gate(), userInitiated: false, exec: exec)
        .hasPrefix("CONFIRMATION REQUIRED"))
    #expect(ran.withLock { $0 }.count == 2)
}

@Test func theShellHarnessPassesOnWhoAsked() {
    let (ran, exec) = recorder()
    let harness = ShellHarness(enabled: true, gate: gate(), exec: exec)
    let ls = #"{"command":"ls","cwd":"/tmp"}"#

    #expect(harness.call("run_shell", arguments: ls, userInitiated: false).output.hasPrefix("CONFIRMATION REQUIRED"))
    #expect(ran.withLock { $0 }.isEmpty)
    #expect(harness.call("run_shell", arguments: ls, userInitiated: true).output.hasPrefix("exit 0"))
    #expect(ran.withLock { $0 } == ["ls"])
}

@Test func changingCommandsNeedASpokenYesForThatExactCommand() {
    let (ran, exec) = recorder()
    let g = gate()

    let ask = HerdrTools.runShell("rm old.log", cwd: "/tmp", confirmed: false, g, exec: exec)
    #expect(ask.hasPrefix("CONFIRMATION REQUIRED"))
    #expect(ask.contains("tmp folder") && !ask.contains("/tmp"))                                                  // no raw path
    #expect(HerdrTools.runShell("rm old.log", cwd: "/tmp", confirmed: true, gate(), exec: exec).hasPrefix("NOT DONE")) // model alone
    g.heard("yes")
    #expect(HerdrTools.runShell("rm -rf ~", cwd: "/tmp", confirmed: true, g, exec: exec).hasPrefix("NOT DONE"))       // swapped
    #expect(ran.withLock { $0 }.isEmpty)

    _ = HerdrTools.runShell("rm old.log", cwd: "/tmp", confirmed: false, g, exec: exec)
    g.heard("yes, run it")
    let out = HerdrTools.runShell("rm old.log", cwd: "/tmp", confirmed: true, g, exec: exec)
    #expect(ran.withLock { $0 } == ["rm old.log"])
    #expect(out.hasPrefix("exit 0\n<<<UNTRUSTED TERMINAL OUTPUT"))
}

@Test(arguments: ["ls", "ls -la", "pwd", "du -sh .", "git status", "git branch", "git branch -a",
                  "git branch --show-current", "git log --oneline -n 5", "git diff --stat", "git show HEAD"])
func readOnlyIsRecognized(command: String) { #expect(HerdrTools.isReadOnly(command)) }

@Test(arguments: ["rm old.log", "ls; rm -rf ~", "ls && rm x", "ls | sh", "ls > out", "echo $(rm x)", "ls `rm x`",
                  "cat ~/.ssh/id_rsa", "env", "git push", "git commit -m x", "git checkout main", "git branch new",
                  "git branch -D old", "git branch -dr origin/x", "git branch --delete old", "git diff --output x",
                  "git diff --output=x", "git -C /tmp status", "brew install jq", "touch f", "ls\nrm x", ""])
func everythingElseAsks(command: String) { #expect(!HerdrTools.isReadOnly(command)) }

@Test func missingDirectoryIsRefusedBeforeAsking() {
    #expect(HerdrTools.runShell("ls", cwd: "/no/such/dir", confirmed: false, gate()).contains("not a directory"))
}

@Test func realExecCapturesExitCodeAndOutput() {
    let r = HerdrTools.shellExec("echo out; echo err >&2; exit 3", "/tmp", 10)
    #expect(r.status == 3)
    #expect(r.output.contains("out") && r.output.contains("err"))
    #expect(!r.timedOut)
}

@Test func realExecStopsLongCommandsAndHasNoStdin() {
    let start = Date()
    #expect(HerdrTools.shellExec("sleep 30", "/tmp", 0.5).timedOut)
    #expect(Date().timeIntervalSince(start) < 5)
    #expect(HerdrTools.shellExec("cat", "/tmp", 5).timedOut == false) // stdin is closed, so cat exits at once
}
