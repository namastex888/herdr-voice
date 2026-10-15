import HerdrVoiceCore
import SwiftUI

/// The map of what she can do: the harnesses she controls (the human's to switch), the skills she learned, every
/// change to her and who made it, and how she has grown.
struct SkillsView: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var chat: ChatModel

    var body: some View {
        List {
            if !controller.notice.isEmpty {
                Text(controller.notice).font(.callout).foregroundStyle(.secondary)
            }
            Section("What I can control") {
                ForEach(controller.harnesses) { HarnessRow(controller: controller, harness: $0, loaded: chat.activeSkills.contains($0.id)) }
            }
            Section("What I know") {
                if controller.skills.isEmpty {
                    Text("I'm new here, so I don't know any skills yet. Teach me by voice or in the chat: “when I say start "
                         + "my day, open Mail and Calendar and set the volume to 30”, or tell me how you like a task done. "
                         + "I'll say what I'd save and wait for your yes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(controller.skills) { SkillRow(controller: controller, info: $0) }
            }
            Section("How I've changed") {
                if controller.changes.isEmpty {
                    Text("No changes yet. Each one, mine (after your yes) or yours, shows here and can be reverted.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(controller.changes) { ChangeRow(controller: controller, change: $0) }
            }
            Section("Growth") {
                GrowthView(metrics: controller.metrics, skills: controller.skills.count, facts: controller.facts.count)
            }
        }
        .onAppear { controller.refresh() }
    }
}

/// A status in a few words, coloured by whether it runs.
private struct StatusBadge: View {
    let text: String
    let status: EntryStatus

    var body: some View {
        Text(text).font(.caption2.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .active: .green
        case .disabled, .inactive: .secondary
        case .failed: .red
        }
    }
}

private struct HarnessRow: View {
    @ObservedObject var controller: CompanionController
    let harness: CompanionController.HarnessInfo
    let loaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(harness.title).font(.headline)
                StatusBadge(text: harness.status == .active ? (loaded ? "On · loaded" : "On") : harness.statusText,
                            status: harness.status)
                Spacer()
                Toggle("", isOn: Binding(get: { harness.on }, set: { controller.setHarness(harness.id, on: $0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .help(harness.on ? "Switch \(harness.title) off: she loses these controls" : "Switch \(harness.title) on")
            }
            if harness.name == "mac" {
                Toggle("AppleScript (each script needs your spoken yes)",
                       isOn: Binding(get: { controller.appleScriptOn }, set: { controller.setAppleScript($0) }))
                    .font(.callout)
            }
            if harness.name == "shell" {
                Text("Each command needs your spoken yes.").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("\(harness.actions.count) actions") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(harness.actions, id: \.self) { action in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(action.name).font(.caption.monospaced())
                            Text(action.description).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
        .padding(.vertical, 2)
    }
}

private struct SkillRow: View {
    @ObservedObject var controller: CompanionController
    let info: CompanionController.SkillInfo
    @State private var confirmForget = false

    private var skill: Skill { info.skill }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(skill.title).font(.headline)
                StatusBadge(text: statusText, status: info.status)
                Spacer()
                Button("Forget", role: .destructive) { confirmForget = true }
                    .buttonStyle(.borderless).font(.callout)
            }
            if !skill.summary.isEmpty {
                Text(skill.summary).font(.callout)
            }
            if !skill.needs.isEmpty {
                Text("Needs: " + skill.needs.map { need in controller.harnesses.first { $0.name == need }?.title ?? need }
                    .joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !skill.steps.isEmpty {
                Text("Steps").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(skill.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step.action)\(step.arguments == "{}" ? "" : " \(step.arguments)")")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if !skill.playbook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("How-to notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(skill.playbook).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("Forget \(skill.title)?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { controller.forgetSkill(skill.id) }
        } message: {
            Text("You can bring it back from How I've changed.")
        }
    }

    private var statusText: String {
        switch info.status {
        case .active: "Active"
        case .disabled: "Off"
        case .inactive(let reason): "Inactive: \(reason)"
        case .failed(let error): "Failed: \(error)"
        }
    }
}

private struct ChangeRow: View {
    @ObservedObject var controller: CompanionController
    let change: ChangeRecord

    /// The later change that undid this one, if any.
    private var undoneBy: String? { controller.changes.first { $0.revertOf == change.id }?.id }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(change.summary).font(.callout)
                Text("\(change.by == .user ? "You" : controller.name) · \(change.time.formatted(.relative(presentation: .named)))"
                     + " · \(change.id)" + (undoneBy.map { " · undone by \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert") { controller.revert(change.id) }
                .buttonStyle(.borderless).font(.callout).disabled(undoneBy != nil)
                .help("Put back everything this change touched as it was before it")
        }
        .padding(.vertical, 1)
    }
}

private struct GrowthView: View {
    let metrics: GrowthMetrics
    let skills: Int
    let facts: Int

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            row("Skills I know", skills)
            row("Facts I remember", facts)
            row("Skills you taught me", metrics.skillsTaught)
            row("Skill runs", metrics.replays)
            row("Runs that stopped partway", metrics.replayFailures)
            row("Changes you said yes to", metrics.proposalsApplied)
            row("Changes reverted", metrics.reverted)
        }
        .font(.callout)
    }

    private func row(_ title: String, _ value: Int) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text("\(value)").monospacedDigit()
        }
    }
}
