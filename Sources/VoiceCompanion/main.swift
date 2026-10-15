import AppKit
import HerdrVoiceCore
import VoiceEngine

// An app opened from Finder gets a bare PATH; add the usual tool folders so herdr and friends are found.
let home = NSHomeDirectory()
let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
setenv("PATH", (["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + [path]).joined(separator: ":"), 1)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTest())
}

// One companion at a time: a second would share the mic and hear the first one's voice.
if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
    NSRunningApplication.runningApplications(withBundleIdentifier: id)
        .first { $0.processIdentifier != getpid() }?.activate()
    exit(0)
}

let controller = CompanionController()
controller.start()
signal(SIGINT) { _ in exit(0) }
app.run()
