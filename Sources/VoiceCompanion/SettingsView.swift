import HerdrVoiceCore
import SwiftUI

/// Who she is, what she remembers, how she sounds and routes, and the keys. Every field reads the configuration tree
/// and saves through the registry as the human's own change (logged, revertible); keys go to the Keychain.
struct SettingsView: View {
    @ObservedObject var controller: CompanionController
    @ObservedObject var keys: CompanionKeys
    @State private var keyDrafts: [Provider: String] = [:]
    @State private var jevDraft = ""
    @State private var factDraft = ""
    @State private var confirmReset = false

    var body: some View {
        Form {
            if !controller.notice.isEmpty {
                Text(controller.notice).font(.callout).foregroundStyle(.secondary)
            }
            Section {
                DraftField("Name", value: controller.identity("name")) { controller.setIdentity("name", $0) }
                DraftField("Role", value: controller.identity("role")) { controller.setIdentity("role", $0) }
                DraftField("Personality", value: controller.identity("personality"), lines: 3) {
                    controller.setIdentity("personality", $0)
                }
                DraftField("Learned instructions", value: controller.identity("instructions"), lines: 6,
                           placeholder: "How you like things done. She proposes these as she learns.") {
                    controller.setIdentity("instructions", $0)
                }
            } header: {
                Text("Identity")
            } footer: {
                Text("She can propose changes to these too; hers apply only after your yes.").font(.caption)
            }
            Section("Memory") {
                if controller.facts.isEmpty {
                    Text("Nothing yet. She proposes facts worth keeping (“remember standup is at 10”) and asks first.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(controller.facts, id: \.self) { fact in
                    HStack(alignment: .top) {
                        Text(fact).textSelection(.enabled)
                        Spacer()
                        Button { controller.removeFact(fact) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Forget this")
                    }
                }
                HStack {
                    TextField("Add a fact", text: $factDraft).onSubmit(addFact)
                    Button("Add", action: addFact).disabled(factDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                Picker("Mode", selection: Binding(get: { controller.settings.activation },
                                                  set: { controller.setActivation($0) })) {
                    ForEach(ActivationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(controller.settings.activation.detail).font(.caption).foregroundStyle(.secondary)
                if controller.settings.activation.opensOnRequest {
                    Picker("Key", selection: Binding(get: { controller.settings.activationKey },
                                                     set: { controller.setActivationKey($0) })) {
                        ForEach(ActivationKey.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Stepper("Follow-up: \(Int(controller.settings.followUpSeconds)) s",
                            value: Binding(get: { controller.settings.followUpSeconds },
                                           set: { controller.setFollowUp($0) }),
                            in: CompanionSettings.followUpRange, step: 1)
                }
                if controller.settings.activation == .wakeWord {
                    DraftField("Wake phrase", value: controller.settings.wakePhrase) { controller.setWakePhrase($0) }
                }
                if !controller.activationNote.isEmpty {
                    Text(controller.activationNote).font(.caption).foregroundStyle(.orange)
                    Button("Allow Input Monitoring…") { controller.requestKeyPermission() }
                }
            } header: {
                Text("Listening")
            } footer: {
                Text("Tap the key alone, talk, and she answers once you stop. Tap again to dismiss, double-tap for "
                     + "hands-free, Esc to end. After her reply you can keep talking for the follow-up time; then "
                     + "the session closes so nothing is billed.").font(.caption)
            }
            Section("Voice") {
                Picker("Model", selection: Binding(get: { controller.provider }, set: { controller.chooseProvider($0) })) {
                    ForEach(CompanionKeys.providers, id: \.self) { provider in
                        Text(provider.menuTitle + (keys.hasKey(provider) ? "" : " (no key)")).tag(provider)
                    }
                }
                DraftField("Voice", value: controller.settings.voice ?? "",
                           placeholder: "\(controller.provider.defaultVoice) (the model's default)") {
                    controller.setVoiceName($0)
                }
            }
            Section("API keys (stored in your Keychain)") {
                ForEach(CompanionKeys.providers, id: \.self) { provider in
                    HStack {
                        SecureField("\(provider.menuTitle) key\(keys.hasKey(provider) ? " (saved)" : "")",
                                    text: Binding(get: { keyDrafts[provider] ?? "" }, set: { keyDrafts[provider] = $0 }))
                        Button("Save") {
                            controller.saveKey(keyDrafts[provider] ?? "", for: provider)
                            keyDrafts[provider] = ""
                        }
                        .disabled((keyDrafts[provider] ?? "").isEmpty)
                    }
                }
            }
            Section("Skill routing") {
                Toggle("Route each turn with Jev",
                       isOn: Binding(get: { controller.settings.routeWithJev }, set: { controller.setRouteWithJev($0) }))
                HStack {
                    SecureField("Jev (TypeSafe) key\(keys.jevKey != nil ? " (saved)" : "")", text: $jevDraft)
                    Button("Save") {
                        controller.saveJevKey(jevDraft)
                        jevDraft = ""
                    }
                    .disabled(jevDraft.isEmpty)
                }
                Button("Use MeetingPulse's Jev key") { controller.importJevKey() }
                DraftField("Jev model", value: controller.settings.jevModel) { controller.setJevModel($0) }
                Text(controller.jevRouter == nil ? "Routing by words until Jev is on and has a key."
                     : "Routing with \(controller.settings.jevModel).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Reset to new hire…", role: .destructive) { confirmReset = true }
                    Spacer()
                    Button("Open configuration folder") { controller.openConfigFolder() }
                }
            } footer: {
                Text("Reset forgets every skill, fact and learned instruction and restores her factory identity and "
                     + "settings. Your harness switches, voice model and keys stay.").font(.caption)
            }
        }
        .formStyle(.grouped)
        .alert("Reset \(controller.name) to a new hire?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { controller.resetToNewHire() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("She forgets every skill, fact and learned instruction. You can undo it from Skills → How I've changed.")
        }
    }

    private func addFact() {
        controller.addFact(factDraft)
        factDraft = ""
    }
}

/// A text field that edits a draft and saves on Return or Save, so typing doesn't log a change (and renew the voice's
/// instructions) per keystroke. It follows the saved value when that changes elsewhere (her proposals, a revert).
private struct DraftField: View {
    let title: String
    let value: String
    let lines: Int
    let placeholder: String
    let save: (String) -> Void
    @State private var draft: String

    init(_ title: String, value: String, lines: Int = 1, placeholder: String = "", save: @escaping (String) -> Void) {
        self.title = title
        self.value = value
        self.lines = lines
        self.placeholder = placeholder
        self.save = save
        _draft = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                TextField(placeholder.isEmpty ? title : placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...max(lines, 1)).labelsHidden()
                    .onSubmit { save(draft) }
                if draft != value {
                    Button("Save") { save(draft) }
                    Button("Cancel") { draft = value }.buttonStyle(.borderless)
                }
            }
        }
        .onChange(of: value) { _, saved in draft = saved }
    }
}
