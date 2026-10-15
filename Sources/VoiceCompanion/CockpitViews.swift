import Charts
import HerdrVoiceCore
import SwiftUI

// Home is the cockpit: "Welcome back", the headline widgets (each opens a chart of its day-by-day evolution), and
// the sections below: Running now, Recent conversations, Week in numbers, Cost trend. Which widgets and sections,
// and in what order, is her setting `settings.dashboard`, which she changes by voice.

struct HomeScreen: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var model: PhoneModel
    @ObservedObject var numbers: MetricsRecorder
    @ObservedObject var agents: AgentsWatcher
    @ObservedObject var recorder: ConversationRecorder
    @Environment(\.phoneTheme) private var theme

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        let layout = controller.dashboard, today = numbers.snapshot.day(Date())
        ZStack {
            Wallpaper().padding(.top, -StatusBar.height)
            VStack(spacing: 0) {
                PhoneScroll {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(layout.widgets) { item in
                                WidgetCard(item: item, reading: WidgetReading.of(item, day: today, agents: agents.counts)) {
                                    model.go(.detail(item))
                                }
                            }
                        }
                        ForEach(layout.sections) { section in
                            switch section {
                            case .running: RunningNow(agents: agents)
                            case .recent: RecentConversations(recorder: recorder, model: model)
                            case .week: WeekInNumbers(numbers: numbers, skillsTaught: controller.metrics.skillsTaught)
                            case .trend: CostTrend(numbers: numbers) { model.go(.detail(.cost)) }
                            default: EmptyView()
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 16)
                }
                SearchPill(controller: controller, model: model)
                    .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 30)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Welcome back, \(controller.userName)").font(.system(size: 22, weight: .regular))
                .foregroundStyle(theme.onSurface).lineLimit(1).minimumScaleFactor(0.7)
            TimelineView(.everyMinute) { context in
                Text("\(context.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))) · "
                     + "\(controller.name) · \(controller.chat.controls.state)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 6)
    }
}

/// A headline number with its base; tap for its chart.
struct WidgetCard: View {
    let item: DashboardItem
    let reading: WidgetReading
    let open: () -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Label(item.title, systemImage: item.symbol).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.primary).lineLimit(1).minimumScaleFactor(0.75)
                Text(reading.value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(reading.measured ? theme.onSurface : theme.onSurfaceVariant)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(reading.base).font(.system(size: 10)).foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.surfaceContainer.opacity(0.92)))
        }
        .buttonStyle(.plain).help("\(item.title): open its chart")
    }
}

/// A titled section of the cockpit.
struct CockpitSection<Content: View>: View {
    let item: DashboardItem
    var trailing: String?
    @ViewBuilder let content: Content
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(item.title, systemImage: item.symbol).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.primary)
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant)
                }
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.surfaceContainer.opacity(0.92)))
        }
    }
}

/// Herdr's agents with their state; tap one to focus it in Herdr.
struct RunningNow: View {
    @ObservedObject var agents: AgentsWatcher
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        CockpitSection(item: .running, trailing: agents.agents.map { "\($0.filter(\.working).count) working" }) {
            if let list = agents.agents {
                if list.isEmpty {
                    Text("No agents in Herdr right now.").font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                }
                ForEach(list.prefix(6)) { agent in
                    Button { agents.focus(agent) } label: {
                        HStack(spacing: 8) {
                            Circle().fill(color(agent)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.target).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    .foregroundStyle(theme.onSurface)
                                Text([agent.kind, agent.title].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.system(size: 10)).lineLimit(1).foregroundStyle(theme.onSurfaceVariant)
                            }
                            Spacer(minLength: 4)
                            Text(agent.status.isEmpty ? "unknown" : agent.status).font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(color(agent).opacity(0.2)))
                                .foregroundStyle(theme.onSurface)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Focus \(agent.target) in Herdr")
                }
            } else {
                Text("Herdr isn't answering (not installed, or its app is off).").font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        }
    }

    private func color(_ agent: RunningAgent) -> Color {
        if agent.working { return theme.success }
        if agent.needsYou { return theme.error }
        return theme.onSurfaceVariant
    }
}

struct RecentConversations: View {
    @ObservedObject var recorder: ConversationRecorder
    @ObservedObject var model: PhoneModel
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        CockpitSection(item: .recent, trailing: recorder.saved.isEmpty ? nil : "\(recorder.saved.count) kept") {
            if recorder.saved.isEmpty {
                Text("Nothing yet. Each conversation is kept here with its audio until you delete it.")
                    .font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
            }
            ForEach(recorder.saved.prefix(3), id: \.id) { transcript in
                ConversationRow(transcript: transcript, carded: false) { model.go(.conversation(transcript.id)) }
            }
            if recorder.saved.count > 3 {
                Button("All conversations") { model.go(.conversations) }.buttonStyle(TonalButton())
            }
        }
    }
}

/// The last seven days in a few numbers, each with its base.
struct WeekInNumbers: View {
    @ObservedObject var numbers: MetricsRecorder
    let skillsTaught: Int
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        let week = numbers.snapshot.lastDays(7, endingAt: Date()).map(\.metrics)
        let sum = { (value: (DayMetrics) -> Double) in week.reduce(0) { $0 + value($1) } }
        let latencyCount = week.reduce(0) { $0 + $1.latencyCount }
        let latency = latencyCount > 0 ? "\(Int((sum { $0.latencyMsTotal } / Double(latencyCount)).rounded())) ms" : "not measured"
        let rows: [(String, String)] = [
            ("Actions run", "\(Int(sum { Double($0.actions) })) in \(Int(sum { Double($0.turns) })) turns"),
            ("Approvals", "\(Int(sum { Double($0.approvalsGiven) })) given of \(Int(sum { Double($0.approvalsAsked) })) asked"),
            ("Skills learned", "\(skillsTaught) so far"),
            ("Agent time", WidgetReading.duration(sum { $0.agentSeconds })),
            ("Response time", latencyCount > 0 ? "\(latency), \(latencyCount) turns" : latency),
            ("Errors", "\(Int(sum { Double($0.errors) }))"),
        ]
        CockpitSection(item: .week, trailing: "last 7 days") {
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0).font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                    Spacer()
                    Text(row.1).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(theme.onSurface)
                }
            }
        }
    }
}

/// Seven days of cost by provider as a sparkline, and the cost per conversation.
struct CostTrend: View {
    @ObservedObject var numbers: MetricsRecorder
    let open: () -> Void
    @Environment(\.phoneTheme) private var theme

    var body: some View {
        let week = numbers.snapshot.lastDays(7, endingAt: Date())
        let total = week.reduce(0) { $0 + $1.metrics.totalCost }
        let conversations = week.reduce(0) { $0 + $1.metrics.conversations }
        let points = CostPoint.points(week)
        CockpitSection(item: .trend, trailing: WidgetReading.usd(total) + " this week") {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    Chart(points) { point in
                        LineMark(x: .value("Day", point.day, unit: .day), y: .value("USD", point.usd))
                            .foregroundStyle(by: .value("Provider", point.provider))
                            .interpolationMethod(.monotone)
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden)
                    .chartLegend(position: .bottom, spacing: 4)
                    .environment(\.colorScheme, .dark)
                    .frame(height: 70)
                    Text(conversations > 0 ? "\(WidgetReading.usd(total / Double(conversations))) per conversation "
                         + "(\(conversations) this week)" : "No conversations this week yet.")
                        .font(.system(size: 11)).foregroundStyle(theme.onSurfaceVariant)
                }
            }
            .buttonStyle(.plain).help("Open the cost chart")
        }
    }
}

/// One day's cost for one provider (every provider of the period gets a point each day, zero or not).
struct CostPoint: Identifiable {
    let day: Date
    let provider: String
    let usd: Double
    var id: String { "\(day.timeIntervalSince1970)-\(provider)" }

    static func points(_ days: [(date: Date, metrics: DayMetrics)]) -> [CostPoint] {
        let providers = Set(days.flatMap { $0.metrics.cost.keys }).sorted()
        guard !providers.isEmpty else { return days.map { CostPoint(day: $0.date, provider: "none", usd: 0) } }
        return days.flatMap { day in
            providers.map { CostPoint(day: day.date, provider: Self.title($0), usd: day.metrics.cost[$0] ?? 0) }
        }
    }

    static func title(_ provider: String) -> String { Provider(rawValue: provider)?.menuTitle ?? provider }
}

// MARK: detail

/// A widget's day-by-day evolution: today's reading, a chart of the last two weeks, and where the numbers come from.
struct CockpitDetailScreen: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var numbers: MetricsRecorder
    @ObservedObject var agents: AgentsWatcher
    @ObservedObject var history: CockpitHistory
    @ObservedObject var model: PhoneModel
    let item: DashboardItem
    @Environment(\.phoneTheme) private var theme

    static let days = 14

    var body: some View {
        let local = numbers.snapshot.lastDays(Self.days, endingAt: Date())
        let source = history.days(for: local)
        let today = source.days.last?.metrics ?? DayMetrics()
        let reading = WidgetReading.of(item, day: today, agents: agents.counts)
        VStack(spacing: 0) {
            TopBar(title: item.title, back: { model.go(.home) })
            PhoneScroll {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reading.value).font(.system(size: 34, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(reading.measured ? theme.onSurface : theme.onSurfaceVariant)
                        Text("Today · \(reading.base)").font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                    }
                    .padding(.horizontal, 6)
                    if let series = WidgetReading.series(item) {
                        Card(title: "Last \(Self.days) days", footer: source.label) {
                            chart(source.days, series: series).frame(height: 170)
                        }
                        summary(source.days, series: series)
                    } else {
                        Card(title: "Not measured") {
                            Text(item == .shipped
                                 ? "Shipped work is counted once the Genie bridge reports what landed; until then this "
                                     + "stays not measured rather than a guess."
                                 : "This has no daily history.")
                                .font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 30)
            }
        }
        .background(theme.surface)
        .onAppear { history.refresh() }
    }

    @ViewBuilder
    private func chart(_ days: [(date: Date, metrics: DayMetrics)],
                       series: (unit: String, value: (DayMetrics) -> Double)) -> some View {
        let money = item == .cost || item == .trend
        let counts = ![.cost, .trend, .talk, .agentTime, .latency].contains(item)
        Group {
            if money {
                Chart(CostPoint.points(days)) { point in
                    BarMark(x: .value("Day", point.day, unit: .day), y: .value("USD", point.usd))
                        .foregroundStyle(by: .value("Provider", point.provider))
                }
                .chartLegend(position: .bottom)
            } else {
                Chart(days, id: \.date) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value(series.unit, series.value(day.metrics)))
                        .foregroundStyle(theme.primary)
                }
                .chartYAxisLabel(series.unit)
            }
        }
        // Ticks away from the trailing edge, so the last date isn't cut; dates and numbers written one way.
        .chartXAxis {
            AxisMarks(values: Self.dateTicks(days.map(\.date))) { value in
                AxisGridLine().foregroundStyle(theme.outlineVariant.opacity(0.5))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US")).month(.abbreviated).day()))
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                }
            }
        }
        .chartYAxis {
            if counts {
                AxisMarks(values: Self.wholeTicks(days.map { series.value($0.metrics) })) { value in
                    AxisGridLine().foregroundStyle(theme.outlineVariant.opacity(0.5))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text("\(Int(v))").foregroundStyle(theme.onSurfaceVariant) }
                    }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(theme.outlineVariant.opacity(0.5))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(money ? String(format: "$%.2f", v) : String(format: "%g", v))
                                .foregroundStyle(theme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
        // The phone is dark and its numbers are written one way, whatever the Mac's own settings.
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    /// Every fourth day, ending two days before the last, so no label sits on the trailing edge.
    static func dateTicks(_ dates: [Date]) -> [Date] {
        guard dates.count > 2 else { return dates }
        return stride(from: dates.count - 3, through: 0, by: -4).map { dates[$0] }.reversed()
    }

    /// Whole-number gridlines for a count, about four of them.
    static func wholeTicks(_ values: [Double]) -> [Double] {
        let top = max(1, Int((values.max() ?? 0).rounded(.up)))
        let step = max(1, Int((Double(top) / 4).rounded(.up)))
        return stride(from: 0, through: top, by: step).map(Double.init)
    }

    private func summary(_ days: [(date: Date, metrics: DayMetrics)],
                         series: (unit: String, value: (DayMetrics) -> Double)) -> some View {
        let lastWeek = days.suffix(7)
        let week = lastWeek.map { series.value($0.metrics) }
        let total = week.reduce(0, +), active = week.filter { $0 > 0 }.count
        // Response time is weighted by turns, as Week in numbers counts it; agents are a daily peak, not a sum.
        let turns = lastWeek.reduce(0) { $0 + $1.metrics.latencyCount }
        let latency = turns > 0 ? lastWeek.reduce(0) { $0 + $1.metrics.latencyMsTotal } / Double(turns) : 0
        let format = { (value: Double) -> String in
            switch item {
            case .cost, .trend: WidgetReading.usd(value)
            case .talk: WidgetReading.duration(value * 60)
            case .agentTime: WidgetReading.duration(value * 3600)
            case .agents: "\(Int(value))"
            case .latency: "\(Int(value.rounded())) ms"
            default: "\(Int(value.rounded()))"
            }
        }
        return Card(title: "This week") {
            HStack {
                Text(item == .latency ? "Average per turn" : item == .agents ? "Most at once" : "Total")
                    .font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                Spacer()
                Text(item == .latency ? format(latency) : item == .agents ? format(week.max() ?? 0) : format(total))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.onSurface)
            }
            HStack {
                Text("Days with any").font(.system(size: 12)).foregroundStyle(theme.onSurfaceVariant)
                Spacer()
                Text("\(active) of 7").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.onSurface)
            }
        }
    }
}
