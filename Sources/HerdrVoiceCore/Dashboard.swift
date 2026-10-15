import Foundation

/// What the cockpit can show: headline widgets (a number with its base, opening a detail chart) and sections.
public enum DashboardItem: String, CaseIterable, Codable, Sendable, Identifiable {
    // Widgets.
    case cost, talk, agents, shipped, agentTime, latency, actions, approvals, errors, conversations
    // Sections.
    case running, recent, week, trend

    public var id: String { rawValue }

    public var isWidget: Bool {
        switch self {
        case .running, .recent, .week, .trend: false
        default: true
        }
    }

    public var title: String {
        switch self {
        case .cost: "Cost today"
        case .talk: "Talk time"
        case .agents: "Agents working"
        case .shipped: "Shipped"
        case .agentTime: "Agent time"
        case .latency: "Response time"
        case .actions: "Actions run"
        case .approvals: "Approvals"
        case .errors: "Errors"
        case .conversations: "Conversations"
        case .running: "Running now"
        case .recent: "Recent conversations"
        case .week: "Week in numbers"
        case .trend: "Cost trend"
        }
    }

    public var symbol: String {
        switch self {
        case .cost: "dollarsign.circle.fill"
        case .talk: "waveform"
        case .agents: "cpu.fill"
        case .shipped: "shippingbox.fill"
        case .agentTime: "timer"
        case .latency: "bolt.fill"
        case .actions: "hammer.fill"
        case .approvals: "checkmark.seal.fill"
        case .errors: "exclamationmark.triangle.fill"
        case .conversations: "bubble.left.and.bubble.right.fill"
        case .running: "play.circle.fill"
        case .recent: "clock.arrow.circlepath"
        case .week: "calendar"
        case .trend: "chart.xyaxis.line"
        }
    }

    public static let defaultWidgets: [DashboardItem] = [.cost, .talk, .agents, .shipped]
    public static let defaultSections: [DashboardItem] = [.running, .recent, .week, .trend]

    /// An item by its id, its title or a few words of it ("agent time", "the cost trend", "talk").
    public static func named(_ words: String) -> DashboardItem? {
        let wanted = words.lowercased().filter { $0.isLetter || $0 == " " }
            .replacingOccurrences(of: "the ", with: "").trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        if let exact = allCases.first(where: { $0.rawValue.lowercased() == wanted.replacingOccurrences(of: " ", with: "")
            || $0.title.lowercased() == wanted }) { return exact }
        let aliases: [(String, DashboardItem)] = [
            ("agent time", .agentTime), ("agents time", .agentTime), ("running", .running), ("recent", .recent),
            ("week", .week), ("trend", .trend), ("sparkline", .trend), ("cost", .cost), ("spend", .cost),
            ("talk", .talk), ("agent", .agents), ("ship", .shipped), ("latency", .latency), ("response", .latency),
            ("action", .actions), ("tool", .actions), ("approval", .approvals), ("error", .errors),
            ("conversation", .conversations),
        ]
        return aliases.first { wanted.contains($0.0) }?.1
    }
}

/// Which widgets and sections the cockpit shows, in order: `settings.dashboard` in her configuration, the human's
/// setting, which she changes by voice when asked (`set_dashboard`).
public struct DashboardLayout: Equatable, Sendable {
    public var widgets: [DashboardItem]
    public var sections: [DashboardItem]

    public init(widgets: [DashboardItem] = DashboardItem.defaultWidgets,
                sections: [DashboardItem] = DashboardItem.defaultSections) {
        self.widgets = widgets
        self.sections = sections
    }

    /// From `settings.dashboard` (`{"widgets": [...], "sections": [...]}`); the defaults where it says nothing.
    public init(_ value: JSONValue?) {
        func items(_ key: String, widgets: Bool) -> [DashboardItem]? {
            guard case .object(let object)? = value, let list = object[key]?.array else { return nil }
            var seen = Set<DashboardItem>()
            return list.compactMap { $0.string.flatMap(DashboardItem.init(rawValue:)) }
                .filter { $0.isWidget == widgets && seen.insert($0).inserted }
        }
        self.init(widgets: items("widgets", widgets: true) ?? DashboardItem.defaultWidgets,
                  sections: items("sections", widgets: false) ?? DashboardItem.defaultSections)
    }

    public var json: JSONValue {
        .object(["widgets": .array(widgets.map { .string($0.rawValue) }),
                 "sections": .array(sections.map { .string($0.rawValue) })])
    }

    /// A change asked for by voice: a whole new order, items to show or hide, or one to put on top.
    public struct Edit: Equatable, Sendable {
        public var widgets: [DashboardItem]?
        public var sections: [DashboardItem]?
        public var show: [DashboardItem] = []
        public var hide: [DashboardItem] = []
        public var top: DashboardItem?

        public init(widgets: [DashboardItem]? = nil, sections: [DashboardItem]? = nil, show: [DashboardItem] = [],
                    hide: [DashboardItem] = [], top: DashboardItem? = nil) {
            self.widgets = widgets
            self.sections = sections
            self.show = show
            self.hide = hide
            self.top = top
        }

        public var isEmpty: Bool { widgets == nil && sections == nil && show.isEmpty && hide.isEmpty && top == nil }

        /// Reads `set_dashboard`'s arguments, naming any item it doesn't know.
        public init(arguments args: [String: Any]) throws {
            func list(_ key: String) throws -> [DashboardItem]? {
                guard let raw = args[key] else { return nil }
                let names = (raw as? [String]) ?? (raw as? String).map { [$0] } ?? []
                return try names.map { name in
                    guard let item = DashboardItem.named(name) else {
                        throw ComponentError("there is no dashboard item called \(name); they are "
                                             + DashboardItem.allCases.map(\.rawValue).joined(separator: ", "))
                    }
                    return item
                }
            }
            self.init(widgets: try list("widgets"), sections: try list("sections"), show: try list("show") ?? [],
                      hide: try list("hide") ?? [], top: try list("top")?.first)
            if let widgets, widgets.contains(where: { !$0.isWidget }) {
                throw ComponentError("widgets are " + DashboardItem.allCases.filter(\.isWidget).map(\.rawValue)
                    .joined(separator: ", ") + "; sections go in sections")
            }
            if let sections, sections.contains(where: \.isWidget) {
                throw ComponentError("sections are running, recent, week and trend")
            }
            guard !isEmpty else { throw ComponentError("say which widgets or sections to show, hide or put on top") }
        }
    }

    public func applying(_ edit: Edit) -> DashboardLayout {
        var next = self
        if let widgets = edit.widgets { next.widgets = Self.unique(widgets) }
        if let sections = edit.sections { next.sections = Self.unique(sections) }
        for item in edit.hide {
            next.widgets.removeAll { $0 == item }
            next.sections.removeAll { $0 == item }
        }
        for item in edit.show {
            if item.isWidget, !next.widgets.contains(item) { next.widgets.append(item) }
            if !item.isWidget, !next.sections.contains(item) { next.sections.append(item) }
        }
        if let top = edit.top {
            if top.isWidget {
                next.widgets.removeAll { $0 == top }
                next.widgets.insert(top, at: 0)
            } else {
                next.sections.removeAll { $0 == top }
                next.sections.insert(top, at: 0)
            }
        }
        return next
    }

    /// In words, for her answer.
    public var summary: String {
        "widgets: " + (widgets.isEmpty ? "none" : widgets.map(\.title).joined(separator: ", "))
            + "; sections: " + (sections.isEmpty ? "none" : sections.map(\.title).joined(separator: ", "))
    }

    private static func unique(_ items: [DashboardItem]) -> [DashboardItem] {
        var seen = Set<DashboardItem>()
        return items.filter { seen.insert($0).inserted }
    }
}

/// A widget's number and its base, from the day's aggregate and what Herdr says now. Every number shows its base,
/// or "not measured".
public struct WidgetReading: Equatable, Sendable {
    public var value: String
    public var base: String
    public var measured: Bool

    /// `agents`: (working, total) from Herdr now, or nil when Herdr can't be asked.
    public static func of(_ item: DashboardItem, day: DayMetrics, agents: (working: Int, total: Int)?) -> WidgetReading {
        switch item {
        case .cost:
            let perConversation = day.conversations > 0 ? " · \(usd(day.totalCost / Double(day.conversations))) each" : ""
            return WidgetReading(value: usd(day.totalCost),
                                 base: "\(count(day.conversations, "conversation"))\(perConversation)"
                                     + (day.costIsEstimated ? " · estimated" : ""), measured: true)
        case .talk:
            return WidgetReading(value: duration(day.talkSeconds),
                                 base: "you \(duration(day.userTalkSeconds)) · Vox \(duration(day.voxTalkSeconds))",
                                 measured: true)
        case .agents:
            guard let agents else { return WidgetReading(value: "–", base: "Herdr isn't answering", measured: false) }
            return WidgetReading(value: "\(agents.working)", base: "of \(count(agents.total, "agent")) in Herdr",
                                 measured: true)
        case .shipped:
            return WidgetReading(value: "–", base: "not measured until the Genie bridge", measured: false)
        case .agentTime:
            return WidgetReading(value: duration(day.agentSeconds), base: "agents working, sampled every 30 s",
                                 measured: true)
        case .latency:
            guard let latency = day.averageLatencyMs else {
                return WidgetReading(value: "–", base: "no spoken turns yet", measured: false)
            }
            return WidgetReading(value: "\(Int(latency.rounded())) ms",
                                 base: "average of \(count(day.latencyCount, "turn"))", measured: true)
        case .actions:
            return WidgetReading(value: "\(day.actions)", base: "in \(count(day.turns, "turn"))"
                                     + (day.delegations > 0 ? " · \(day.delegations) delegated" : ""), measured: true)
        case .approvals:
            return WidgetReading(value: "\(day.approvalsGiven)/\(day.approvalsAsked)", base: "given of asked",
                                 measured: true)
        case .errors:
            return WidgetReading(value: "\(day.errors)", base: "in \(count(day.turns, "turn"))", measured: true)
        case .conversations:
            return WidgetReading(value: "\(day.conversations)", base: "\(count(day.turns, "turn"))", measured: true)
        case .running, .recent, .week, .trend:
            return WidgetReading(value: "", base: "", measured: false)
        }
    }

    /// The number a detail chart plots per day, and its unit; nil where nothing is measured.
    public static func series(_ item: DashboardItem) -> (unit: String, value: (DayMetrics) -> Double)? {
        switch item {
        case .cost, .trend: ("USD", { $0.totalCost })
        case .talk: ("minutes", { $0.talkSeconds / 60 })
        case .agents: ("most working at once", { Double($0.agentsPeak) })
        case .agentTime: ("hours of agent work", { $0.agentSeconds / 3600 })
        case .latency: ("ms", { $0.averageLatencyMs ?? 0 })
        case .actions: ("actions", { Double($0.actions) })
        case .approvals: ("approvals asked", { Double($0.approvalsAsked) })
        case .errors: ("errors", { Double($0.errors) })
        case .conversations, .recent: ("conversations", { Double($0.conversations) })
        case .shipped, .running, .week: nil
        }
    }

    public static func usd(_ value: Double) -> String {
        value >= 1 || value == 0 ? String(format: "$%.2f", value) : String(format: "$%.3f", value)
    }

    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

/// One Herdr agent as `list_agents` reports it (Herdr's own state words: working, blocked, idle, done).
public struct RunningAgent: Equatable, Sendable, Identifiable {
    public let target: String
    public let kind: String
    public let status: String
    public let cwd: String
    public let title: String

    public var id: String { target }
    public var working: Bool { status == "working" }
    public var needsYou: Bool { status == "blocked" }

    public init(target: String, kind: String, status: String, cwd: String = "", title: String = "") {
        self.target = target
        self.kind = kind
        self.status = status
        self.cwd = cwd
        self.title = title
    }

    /// The agents in the Herdr harness's `list_agents` answer, or nil when it isn't a list (an error, no Herdr).
    public static func parse(_ output: String) -> [RunningAgent]? {
        guard let list = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else { return nil }
        return list.map { a in
            RunningAgent(target: a["target"] as? String ?? "", kind: a["kind"] as? String ?? "",
                         status: a["status"] as? String ?? "", cwd: a["cwd"] as? String ?? "",
                         title: a["title"] as? String ?? "")
        }
    }
}
