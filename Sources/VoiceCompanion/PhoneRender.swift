import AppKit
import HerdrVoiceCore
import SwiftUI
import VoiceEngine

/// Draws the phone to images, without a window: the self-test checks every screen renders, and
/// `VoiceCompanion --render-phone DIR` writes them as PNGs to look at. Text fields and scroll views draw as plain
/// content there (`phoneSnapshot`), which an image renderer can draw.
@MainActor enum PhoneRender {
    struct Shot {
        let name: String
        var screen: PhoneScreen = .home
        var shade = false
        var morph: CGFloat = 1
        var frame = LiveLevels.Frame()
        /// How far scrolled content is scrolled.
        var scroll: CGFloat = 0
    }

    /// Every screen, the orb, a frame of the morph between them, and a conversation's sheet.
    static func shots(appID: String?) -> [Shot] {
        let listening = LiveLevels.Frame(look: .mood(.listening), mic: 0.55, voice: 0, thinking: false, listening: true,
                                         time: 2.3)
        var shots = [
            Shot(name: "orb", morph: 0, frame: LiveLevels.Frame(look: .resting, time: 1.4)),
            Shot(name: "orb-listening", morph: 0, frame: listening),
            Shot(name: "morph", screen: .lock, morph: 0.45, frame: listening),
            Shot(name: "lock", screen: .lock),
            Shot(name: "home", screen: .home),
            Shot(name: "home-sections", screen: .home, scroll: 330),
            Shot(name: "home-bottom", screen: .home, scroll: 560),
            Shot(name: "chat", screen: .messages),
            Shot(name: "conversations", screen: .conversations),
            Shot(name: "settings", screen: .settings),
            Shot(name: "skills", screen: .skills),
            Shot(name: "drawer", screen: .home, shade: true),
        ]
        shots += DashboardItem.allCases.filter(\.isWidget).map { Shot(name: "detail-\($0.rawValue)", screen: .detail($0)) }
        if let appID { shots.append(Shot(name: "app", screen: .app(appID))) }
        return shots
    }

    /// One shot of the controller's phone as it stands (its chat, skills, settings), at 2x.
    static func image(_ shot: Shot, controller: CompanionController) -> CGImage? {
        let phone = controller.phone
        phone.screen = shot.screen
        phone.shadeOpen = shot.shade
        phone.morph = shot.morph
        phone.expanded = shot.morph > 0
        controller.live.show(shot.frame)
        let size = CGSize(width: PhoneWindow.phoneSize.width + PhoneWindow.pad * 2,
                          height: PhoneWindow.phoneSize.height + PhoneWindow.pad * 2)
        let root = PhoneRoot(controller: controller, model: phone, live: controller.live)
            .environment(\.phoneSnapshot, true)
            .environment(\.phoneSnapshotScroll, shot.scroll)
            .frame(width: size.width, height: size.height)
            .background(Color(red: 0.11, green: 0.12, blue: 0.14)) // a desktop behind it, so the glow shows
        let renderer = ImageRenderer(content: root)
        renderer.scale = 2
        return renderer.cgImage
    }

    /// Enough distinct colours that something was drawn, not a blank or a solid fill.
    static func looksDrawn(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data), stride = max(4, length / 4000 / 4 * 4)
        var colours = Set<UInt32>()
        for offset in Swift.stride(from: 0, to: length - 4, by: stride) {
            colours.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
        }
        return colours.count > 40
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}

/// `VoiceCompanion --render-phone DIR`: a companion with a scratch configuration (two learned skills, a few lines of
/// conversation and a report), no session, no network; writes each shot as DIR/<name>.png.
@MainActor func renderPhone(to directory: String) -> Int32 {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vc-render-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let controller = CompanionController(store: CompanionStore(directory: scratch), legacyDefaults: nil,
                                         gate: ConfirmGate(minDelay: 0, wait: 0),
                                         home: VoxHome(root: scratch.appendingPathComponent("vox")))
    stageDemo(controller)
    let folder = URL(fileURLWithPath: directory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var failed = 0
    for shot in PhoneRender.shots(appID: "harness.mac") {
        let url = folder.appendingPathComponent("\(shot.name).png")
        guard let image = PhoneRender.image(shot, controller: controller), PhoneRender.writePNG(image, to: url) else {
            print("✘ \(shot.name)")
            failed += 1
            continue
        }
        print("wrote \(url.path)")
    }
    // A conversation: the lock screen with the assistant sheet, listening.
    stageConversation(controller)
    var listening = PhoneRender.Shot(name: "assistant", screen: .lock)
    listening.frame = LiveLevels.Frame(look: .mood(.listening), mic: 0.6, voice: 0, thinking: false, time: 3.1)
    var cooling = PhoneRender.Shot(name: "assistant-cooldown", screen: .lock)
    cooling.frame = LiveLevels.Frame(look: .mood(.listening), mic: 0.1, voice: 0, thinking: false, time: 3.4, cooldown: 0.6)
    var following = PhoneRender.Shot(name: "assistant-followup", screen: .home)
    following.frame = LiveLevels.Frame(look: .mood(.speaking), mic: 0, voice: 0.5, thinking: false, time: 4.2, followUp: 0.65)
    let start = Date()
    for (index, shot) in [listening, cooling, following].enumerated() {
        // Each shot's own moment of the conversation: listening, the cooldown after speech, the follow-up window.
        if index == 1 {
            controller.activation(.speechStarted, at: start.addingTimeInterval(0.4))
            controller.activation(.speechStopped, at: start.addingTimeInterval(1.2))
        } else if index == 2 {
            controller.activation(.tick, at: start.addingTimeInterval(1.8))
            controller.activation(.assistant(busy: true), at: start.addingTimeInterval(2))
            controller.activation(.assistant(busy: false), at: start.addingTimeInterval(3))
        }
        let url = folder.appendingPathComponent("\(shot.name).png")
        if let image = PhoneRender.image(shot, controller: controller), PhoneRender.writePNG(image, to: url) {
            print("wrote \(url.path)")
        } else {
            failed += 1
        }
    }
    controller.activation(.reset)
    return failed == 0 ? 0 : 1
}

/// Two learned skills and a short conversation, so the screens show what a used companion looks like.
@MainActor private func stageDemo(_ controller: CompanionController) {
    let skills = [
        Skill(id: "start-my-day", title: "Start my day", summary: "Opens Mail and Calendar and sets the volume to 30.",
              needs: ["mac"], steps: [Skill.Step(action: "open_app", arguments: #"{"name":"Mail"}"#),
                                      Skill.Step(action: "open_app", arguments: #"{"name":"Calendar"}"#),
                                      Skill.Step(action: "set_volume", arguments: #"{"percent":30}"#)], playbook: ""),
        Skill(id: "focus-mode", title: "Focus", summary: "Dark mode on and notifications hushed.",
              needs: ["mac"], steps: [Skill.Step(action: "set_dark_mode", arguments: #"{"on":true}"#)], playbook: ""),
    ]
    _ = try? controller.registry.applyUserEdit("Demo skills") { tree in
        for skill in skills { tree.entries.append(skill.entry) }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1)) // the settle reaches the controller on the next turn
    let chat = controller.chat
    chat.append(.you("Open Safari and set the volume to 30"))
    chat.append(.toolCall(name: "open_app", arguments: #"{"name":"Safari"}"#))
    chat.append(.toolResult(name: "open_app", output: "Opened Safari."))
    chat.append(.toolCall(name: "set_volume", arguments: #"{"percent":30}"#))
    chat.append(.toolResult(name: "set_volume", output: "Volume set to 30%."))
    chat.append(.voice("Done: Safari's open and the volume is at 30."))
    chat.append(.you("When I say focus, turn on dark mode"))
    chat.append(.voice("Want me to learn that as a skill called Focus?"))
    chat.append(.note("← claude-code settled"))
    stageVoiceNotes(controller)
    stageCockpit(controller)
}

/// A week of numbers and three Herdr agents, so the cockpit shows what a used Vox looks like.
@MainActor func stageCockpit(_ controller: CompanionController) {
    var ledger = MetricsLedger()
    let calendar = Calendar.current, today = Date()
    for back in 0..<14 {
        guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
        let wave = 1 + sin(Double(back) * 0.9)
        ledger.update(date) { day in
            day.addCost(0.18 * wave, provider: "grok", estimated: false)
            if back % 3 == 0 { day.addCost(0.11 * wave, provider: "openai", estimated: false) }
            day.conversations = 2 + back % 4
            day.turns = 9 + back % 5
            day.actions = 6 + back % 7
            day.delegations = back % 3
            day.approvalsAsked = 2 + back % 2
            day.approvalsGiven = 2
            day.userTalkSeconds = 140 + 40 * wave
            day.voxTalkSeconds = 210 + 50 * wave
            day.latencyMsTotal = Double(day.turns) * (780 + 120 * wave)
            day.latencyCount = day.turns
            day.agentSeconds = 3600 * (1.2 + wave)
            day.agentsPeak = 1 + back % 4
            day.errors = back % 4 == 1 ? 1 : 0
        }
    }
    controller.numbers.stage(ledger)
    controller.agents.stage([
        RunningAgent(target: "fix-login", kind: "claude", status: "working", title: "Fixing the login redirect"),
        RunningAgent(target: "docs-pass", kind: "codex", status: "blocked", title: "Needs approval to run tests"),
        RunningAgent(target: "claude-3", kind: "claude", status: "done", title: "Release notes"),
    ])
}

/// A short spoken exchange through the recorder, as the session would feed it: your speech as sent, her audio as
/// played, both transcripts, and a typed turn; then the conversation ends and is saved.
@MainActor func stageVoiceNotes(_ controller: CompanionController) {
    let recorder = controller.recorder, now = Date()
    recorder.mic(syntheticSpeech(seconds: 1.6, seed: 1), at: now)
    recorder.played(syntheticSpeech(seconds: 2.4, seed: 2), item: "item-1", at: now.addingTimeInterval(2))
    recorder.heard(.voice("Done: Safari's open and the volume is at 30."), at: now.addingTimeInterval(2.2))
    recorder.heard(.you("Open Safari and set the volume to 30"), at: now.addingTimeInterval(2.3))
    recorder.typed("Thanks!", at: now.addingTimeInterval(6))
    recorder.end(at: now.addingTimeInterval(7))
    recorder.drain()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1)) // the saved list reaches main
}

/// Speech-like PCM16 24 kHz: a tone whose loudness rises and falls like syllables.
func syntheticSpeech(seconds: Double, seed: Double) -> Data {
    let count = Int(seconds * Double(PCM.rate))
    var samples = (0..<count).map { i -> Int16 in
        let t = Double(i) / Double(PCM.rate)
        let envelope = 0.15 + 0.85 * abs(sin(t * (3.1 + seed) + seed)) * abs(sin(t * 0.9 + seed * 2))
        return Int16(0.4 * envelope * 32767 * sin(t * 2 * .pi * (180 + 40 * seed))).littleEndian
    }
    return Data(bytes: &samples, count: count * 2)
}

@MainActor private func stageConversation(_ controller: CompanionController) {
    setenv("HERDR_VOICE_ECHO_CANCEL", "0", 1)
    let session = Realtime(provider: .local, key: "", voice: "", host: controller.registry,
                           instructions: controller.registry.instructions, greeting: controller.registry.greeting)
    controller.attach(session)
    session.onUserTurn = nil
    controller.activation(.tap)
    controller.phoneReason = .user // the sheet rises over what you opened yourself
    controller.chat.append(.you("What's on my calendar this afternoon?"))
    controller.chat.append(.voice("Two things: design review at three, and a call with Ana at four thirty."))
}
