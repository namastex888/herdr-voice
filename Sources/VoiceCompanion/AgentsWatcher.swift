import Foundation
import HerdrVoiceCore

/// The cockpit's "Running now": Herdr's agents and their state, asked through the Herdr harness's own `list_agents`
/// off the main thread, every few seconds while the cockpit is on screen and every half minute otherwise (which also
/// samples the day's agent time). A tap focuses one in Herdr through the harness's `focus`.
@MainActor final class AgentsWatcher: ObservableObject {
    static let fastInterval: TimeInterval = 5
    static let slowInterval: TimeInterval = 30

    /// The agents Herdr reported last, or nil while Herdr can't be asked (not installed, harness off).
    @Published private(set) var agents: [RunningAgent]?
    /// Seconds of agent work, sampled: the agents working at the last look, times the time since.
    var onAgentTime: ((Double) -> Void)?
    /// How many agents are working at each look.
    var onWorking: ((Int) -> Void)?
    /// Whether the cockpit is on screen (look more often).
    var watched: () -> Bool = { false }

    private let list: @Sendable () -> String
    private let focusAgent: @Sendable (String) -> String
    private var timer: Timer?
    private var lastLook: Date?
    private var asking = false

    init(list: @escaping @Sendable () -> String, focus: @escaping @Sendable (String) -> String) {
        self.list = list
        focusAgent = focus
    }

    var working: Int { agents?.filter(\.working).count ?? 0 }

    /// (working, total) for the widgets, or nil while Herdr can't be asked.
    var counts: (working: Int, total: Int)? { agents.map { ($0.filter(\.working).count, $0.count) } }

    func start() {
        guard timer == nil else { return }
        look()
        timer = Timer.scheduledTimer(withTimeInterval: Self.fastInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick(at now: Date = Date()) {
        let interval = watched() ? Self.fastInterval : Self.slowInterval
        if lastLook.map({ now.timeIntervalSince($0) >= interval - 0.5 }) ?? true { look() }
    }

    /// Asks Herdr now (off the main thread).
    func look() {
        guard !asking else { return }
        asking = true
        let list = list
        Task.detached(priority: .utility) {
            let output = list()
            await MainActor.run { [weak self] in
                self?.asking = false
                self?.apply(output)
            }
        }
    }

    /// What Herdr answered: the list, and the agent time since the last look.
    func apply(_ output: String, at now: Date = Date()) {
        if let lastLook, let agents {
            let seconds = min(now.timeIntervalSince(lastLook), Self.slowInterval * 2)
            let busy = agents.filter(\.working).count
            if busy > 0, seconds > 0 { onAgentTime?(Double(busy) * seconds) }
        }
        lastLook = now
        let next = RunningAgent.parse(output)
        if next != agents { agents = next }
        if let next { onWorking?(next.filter(\.working).count) }
    }

    /// Brings the agent into view in Herdr, then looks again.
    func focus(_ agent: RunningAgent) {
        let focusAgent = focusAgent, target = agent.target
        Task.detached(priority: .userInitiated) {
            _ = focusAgent(target)
            await MainActor.run { [weak self] in self?.look() }
        }
    }

    /// Fixed agents, for the phone's renders and the self-test.
    func stage(_ staged: [RunningAgent]?) {
        agents = staged
    }
}
