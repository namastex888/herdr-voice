import Foundation
import HerdrVoiceCore

/// Where a detail chart's days come from: the local aggregate (`~/.vox/metrics.json`), always there and instant.
@MainActor final class CockpitHistory: ObservableObject {
    /// The days to chart, oldest first, and where they come from in words.
    func days(for local: [(date: Date, metrics: DayMetrics)]) -> (days: [(date: Date, metrics: DayMetrics)], label: String) {
        (local, "From this Mac (~/.vox/metrics.json).")
    }

    func refresh() {}
}
