import Foundation
import HerdrVoiceCore
import VoiceEngine

/// What the chat panel shows: the conversation, the skills in play, and the session's state.
@MainActor final class ChatModel: ObservableObject {
    struct Line: Identifiable, Equatable {
        /// `ask`: a question waiting for the user's yes; `change`: a change she made to herself.
        enum Kind { case you, voice, tool, result, ask, change, note }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    /// Enough history to scroll back through a session without growing forever.
    static let limit = 400
    /// Tool output is for the voice; the chat shows its start.
    static let resultPreview = 280

    @Published private(set) var lines: [Line] = []
    @Published var activeSkills: [String] = []
    @Published var lastRoute: RouteDecision?
    /// The session controls' state (see `CompanionController.syncControls`).
    @Published var controls = SessionControls()
    @Published var provider: Provider = .grok

    func append(_ event: SessionEvent) {
        switch event {
        case .you(let text): add(.you, text)
        case .voice(let text): add(.voice, text)
        case .toolCall(let name, let arguments): add(.tool, arguments == "{}" ? name : "\(name) \(arguments)")
        case .toolResult(let name, let output):
            // A proposal's question and its outcome are what the user says yes to and gets, so they show whole.
            if let question = Self.question(in: output) {
                add(.ask, "Waiting for your yes: \(question)?")
            } else if SkillRegistry.selfTools.contains(name), output.hasPrefix("Done (change") {
                add(.change, output)
            } else {
                let short = output.count > Self.resultPreview ? output.prefix(Self.resultPreview) + "…" : Substring(output)
                add(.result, "\(name): \(short)")
            }
        case .note(let text): add(.note, text)
        }
    }

    func note(_ text: String) { add(.note, text) }

    /// The question in a CONFIRMATION REQUIRED answer, as the voice is told to ask it.
    static func question(in output: String) -> String? {
        guard output.hasPrefix("CONFIRMATION REQUIRED"), let start = output.range(of: "in one short sentence: "),
              let end = output.range(of: "? Then stop", range: start.upperBound..<output.endIndex) else { return nil }
        return String(output[start.upperBound..<end.lowerBound])
    }

    private func add(_ kind: Line.Kind, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lines.append(Line(kind: kind, text: text))
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
    }
}
