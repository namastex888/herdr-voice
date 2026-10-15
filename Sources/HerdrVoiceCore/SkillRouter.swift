import Foundation

/// What a turn can be routed to: a learned skill, a harness's raw controls, or (see `RouteDecision.chat`) nothing.
public struct RouteOption: Sendable, Equatable {
    /// The entry id: `skill.start-my-day`, `harness.mac`.
    public let id: String
    public let title: String
    /// One sentence: what Jev reads and words match on.
    public let summary: String
    /// More words to match on: a skill's step actions, a harness's action names and descriptions.
    public let keywords: [String]
    /// A learned skill, asked for by name.
    public let learned: Bool

    public init(id: String, title: String, summary: String, keywords: [String] = [], learned: Bool) {
        self.id = id
        self.title = title
        self.summary = summary
        self.keywords = keywords
        self.learned = learned
    }
}

/// What the voice needs for the user's latest words.
public struct RouteDecision: Sendable, Equatable {
    public enum Source: String, Sendable {
        case jev
        case words
    }

    /// A route option's id, or `RouteDecision.chat` when no tool is needed.
    public let skill: String
    public let confidence: Double
    public let source: Source

    public init(skill: String, confidence: Double, source: Source) {
        self.skill = skill
        self.confidence = confidence
        self.source = source
    }

    /// Conversation only: keep whatever tools are loaded.
    public static let chat = "chat"
}

/// Picks what a turn needs among learned skills, harnesses' raw controls and chat. Runs alongside the voice model's
/// reply, so it only ever loads tools for the next steps; the voice can always `use_skill`.
public protocol SkillRouter: Sendable {
    func route(_ utterance: String, recent: [String], options: [RouteOption]) async -> RouteDecision?
}

/// Matches words in the utterance against each option's title, summary and keywords. No network and always
/// there: the fallback when Jev has no key, fails or is slow.
public struct WordRouter: SkillRouter {
    public init() {}

    private static let ignored: Set<String> = ["the", "and", "for", "you", "your", "with", "that", "this", "what",
                                               "can", "please", "could", "would", "into", "from", "out", "all", "now",
                                               "then", "about", "make", "get", "set", "want", "need", "let", "its"]

    public func route(_ utterance: String, recent: [String], options: [RouteOption]) async -> RouteDecision? {
        decide(utterance, options: options)
    }

    public func decide(_ utterance: String, options: [RouteOption]) -> RouteDecision? {
        let said = Self.words(utterance)
        guard !said.isEmpty else { return nil }
        let phrase = utterance.lowercased()
        var best: (option: RouteOption, score: Double)?
        for option in options {
            let known = Self.words(([option.title, option.summary] + option.keywords).joined(separator: " "))
            var score = Double(said.intersection(known).count)
            // A learned skill is asked for by name: its title in the utterance is all but decisive.
            if option.learned, phrase.contains(option.title.lowercased()) { score += 5 }
            if score > (best?.score ?? 0) { best = (option, score) }
        }
        guard let best else { return nil }
        return RouteDecision(skill: best.option.id, confidence: best.score / (best.score + 1), source: .words)
    }

    /// Lowercased words of three letters or more, with simple plurals folded ("apps" → "app") and filler dropped.
    static func words(_ text: String) -> Set<String> {
        let parts = text.lowercased().split { !$0.isLetter }.map(String.init)
        return Set(parts.filter { $0.count >= 3 && !ignored.contains($0) }.map { word in
            word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
        })
    }
}

/// TypeSafe's Jev (System One): one `choice` question over the learned skills, the harnesses' raw controls and "chat".
/// Pinned to an explicit model version, as TypeSafe recommends for stable answers.
public struct JevRouter: SkillRouter {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let defaultModel = "jev-1.14.0"
    static let question = "next_skill"

    private let key: String
    private let model: String
    private let timeout: TimeInterval
    private let transport: Transport

    /// `timeout` is short on purpose: a route that arrives after the voice has answered is no use to that turn.
    public init(key: String, model: String = JevRouter.defaultModel, timeout: TimeInterval = 3,
                transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.key = key
        self.model = model
        self.timeout = timeout
        self.transport = transport
    }

    public func route(_ utterance: String, recent: [String], options: [RouteOption]) async -> RouteDecision? {
        guard !options.isEmpty, let request = request(utterance, recent: recent, options: options),
              let (data, response) = try? await transport(request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return decision(from: data, options: options)
    }

    public func request(_ utterance: String, recent: [String], options: [RouteOption]) -> URLRequest? {
        var criteria: [String: String] = [RouteDecision.chat: "No tool is needed: conversation, a question, or thanks."]
        for option in options.prefix(254) {
            criteria[option.id] = option.learned ? "Learned skill \(option.title): \(option.summary)"
                : "Raw controls, \(option.title): \(option.summary)"
        }
        let body: [String: Any] = [
            "model": model,
            "state": ["latest_user_words": utterance, "earlier_turns": Array(recent.suffix(4))] as [String: Any],
            "questions": [Self.question: [
                "type": "choice",
                "instructions": "A voice assistant controls the user's Mac with skills the user taught it and the raw "
                    + "controls of its harnesses. Which does it need to act on the user's latest words? Prefer a "
                    + "learned skill the words ask for; pick chat when no action is needed.",
                "criteria": criteria,
            ] as [String: Any]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The answer, only if it is for the model asked and names a known option.
    public func decision(from data: Data, options: [RouteOption]) -> RouteDecision? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["model"] as? String == model,
              let answer = (body["answers"] as? [String: Any])?[Self.question] as? [String: Any],
              answer["type"] as? String == "choice",
              let choice = answer["choice"] as? String,
              choice == RouteDecision.chat || options.contains(where: { $0.id == choice }) else { return nil }
        let confidence = (answer["confidence"] as? NSNumber)?.doubleValue ?? 0
        return RouteDecision(skill: choice, confidence: confidence, source: .jev)
    }
}

/// Jev when it has a key and answers in time; the word router otherwise.
public struct CompanionRouter: SkillRouter {
    private let jev: JevRouter?
    private let words = WordRouter()

    public init(jev: JevRouter?) {
        self.jev = jev
    }

    public func route(_ utterance: String, recent: [String], options: [RouteOption]) async -> RouteDecision? {
        if let jev, let decision = await jev.route(utterance, recent: recent, options: options) { return decision }
        return words.decide(utterance, options: options)
    }
}
