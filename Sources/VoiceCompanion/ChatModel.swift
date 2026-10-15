import Foundation
import HerdrVoiceCore
import VoiceEngine

/// What the chat panel shows: the conversation, the skills in play, and the session's state.
@MainActor final class ChatModel: ObservableObject {
    struct Line: Identifiable, Equatable {
        enum Kind { case you, voice, tool, result, note }
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
    @Published var muted = false
    @Published var connected = false
    @Published var provider: Provider = .grok

    func append(_ event: SessionEvent) {
        switch event {
        case .you(let text): add(.you, text)
        case .voice(let text): add(.voice, text)
        case .toolCall(let name, let arguments): add(.tool, arguments == "{}" ? name : "\(name) \(arguments)")
        case .toolResult(let name, let output):
            let short = output.count > Self.resultPreview ? output.prefix(Self.resultPreview) + "…" : Substring(output)
            add(.result, "\(name): \(short)")
        case .note(let text): add(.note, text)
        }
    }

    func note(_ text: String) { add(.note, text) }

    private func add(_ kind: Line.Kind, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lines.append(Line(kind: kind, text: text))
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
    }
}
