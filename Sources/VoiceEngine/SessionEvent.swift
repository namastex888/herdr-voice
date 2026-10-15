/// What a voice session reports to a UI (see `Realtime.onEvent`).
public enum SessionEvent: Sendable, Equatable {
    /// The user's words, spoken (as transcribed) or typed.
    case you(String)
    /// The voice's reply, as transcribed.
    case voice(String)
    case toolCall(name: String, arguments: String)
    case toolResult(name: String, output: String)
    /// A status line: connecting, muted, a watch ending, an error.
    case note(String)
}
