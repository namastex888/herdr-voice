# Voice Companion architecture: a new hire that configures itself

Voice Companion starts like a newly hired assistant. It knows the controls it has (its harnesses) and nothing else:
no skills, no memory. It says so, asks for its first task, and learns from the human. Everything it is (identity,
memory, settings, skills, which harnesses are on) is configuration it can propose to change, and only the human's
own yes applies a change.

The runtime design follows *A Programming Paradigm for Spatiotemporal Composability* (Shi, Zhang, Cui;
arXiv 2608.25512), the formal model behind Cordis/Koishi. Page numbers below refer to it. The paper covers runtime
composition only; memory, learning, routing and approval are this app's own design.

## 1. The configuration tree (paper P9, p.65)

One JSON file is the authoritative record of what runs:
`~/Library/Application Support/Voice Companion/config.json`.

```json
{
  "version": 1,
  "entries": [
    {"id": "harness.mac",   "kind": "harness",  "config": {"harness": "mac", "appleScript": false}},
    {"id": "harness.herdr", "kind": "harness",  "config": {"harness": "herdr"}},
    {"id": "harness.shell", "kind": "harness",  "config": {"harness": "shell"}, "disabled": true},
    {"id": "harness.companion", "kind": "harness", "config": {"harness": "companion"}},
    {"id": "identity",      "kind": "identity", "config": {"name": "Companion", "role": "...", "personality": "...",
                                                            "instructions": ""}},
    {"id": "memory",        "kind": "memory",   "config": {"facts": []}},
    {"id": "settings",      "kind": "settings", "config": {"voice": null, "routeWithJev": true, "jevModel": "jev-1.14.0"}},
    {"id": "skill.start-my-day", "kind": "skill", "config": {
        "title": "Start my day", "summary": "Opens Mail and Calendar and sets the volume to 30.",
        "needs": ["mac"], "steps": [{"action": "open_app", "arguments": "{\"name\":\"Mail\"}"}],
        "playbook": ""}}
  ]
}
```

- **Factory state** is the tree with the harness entries, `identity`, `memory` and `settings`, and no skill entries.
  "Reset to new hire" reconciles back to it (well defined by confluence, P8 p.54).
- **Human-owned vs proposable.** The assistant may propose changes to `identity.*`, `memory.facts`,
  `settings.voice|routeWithJev|jevModel`, and to add, change or remove `skill.*` entries. Harness entries (enabling
  the shell or AppleScript), the confirmation policy and API keys are human-owned: only the app's own UI changes them.
  This answers the paper's write-back and interception caveats (p.65, p.72): a component never writes the tree.
- API keys stay in the Keychain, never in the tree. `settings.provider` (which voice model, which bill) is in the tree
  and human-owned, as are how she listens (`settings.activation`, `activationKey`, `followUpSeconds`, `wakePhrase`)
  and the look (`accent`): `Governance.humanSettingsKeys`, kept by a reset and by her own reverts.
- **Her own app by voice.** `harness.companion` (0.3) offers the app's session, phone screens and settings as tools.
  Its calls are the human's edits made by voice, applied through the human-edit path and logged as the user's
  ("… (by voice)"), never proposals: proposals still can't touch human-owned paths. They apply at once when the user
  asked, and wait for a spoken yes when the model acts on anything else; what raises her power or the bill (the voice
  model, switching on a harness, AppleScript or the shell, a reset) always waits for one. A tree written before 0.3
  gets the entry when it's loaded.
- **What is active is runtime state, not configuration.** Which skills and harness controls are loaded into the
  live session lives in the registry; routing never writes the tree, and reconcile never changes activation. An
  entry's `disabled` is human-owned and persisted. (Keeping routing out of the tree is what keeps confluence true.)
- **Migration from 0.1.0.** With no `config.json`, build the tree from 0.1.0's state: UserDefaults `provider`,
  `allowAppleScript`, `allowShell`, `routeWithJev`, `jevModel`, and every learned skill in
  `Application Support/Voice Companion/skills/*.json`. Then write `config.json`; the old files are left in place.

## 2. Components (P1, P2, P5, p.9–35)

A component kind turns an entry into running behaviour. Each is `(needs, provides, effect)` (Def. 48, p.31):

| Kind | Needs | Provides | Effect (registered under the entry's id, undone on unload) |
|---|---|---|---|
| `harness` | nothing | `harness.<name>` | registers each action as a tool, and a catalog item "controls: <title>" |
| `identity`, `memory`, `settings` | nothing | `identity`, `memory`, `settings` | publishes its config |
| `skill` | `harness.<x>` for each of `needs` | nothing | registers its procedure tool `skill_<id>` (if it has steps) and a catalog item (title, summary, playbook) |

- **Effects are revertible (P1).** An effect returns its inverse; the host chains them per instance and runs them
  last-in-first-out on unload. All registrations go into tables keyed by entry id, so they commute (P4, p.29).
- **Reactive needs (P2, p.18).** A skill whose harness is missing or unavailable (Herdr not installed, shell off) is
  *inactive*, not an error, and becomes active when the harness appears.
- **Lifecycle (P5, p.34).** Inactive → active → unloading. Dependents unload before the provider they need (P6,
  p.36). A changed `config` reloads the entry (unload, then load).
- **Failure containment (P7, p.56).** An effect that throws is rolled back and the entry is marked *failed* with its
  error; everything else keeps running. It is not retried until its configuration changes.
- **Confluence (P8, p.54).** After `reconcile(tree)` the host's state depends only on `tree`, never on the order of
  earlier changes.
- **One emission per settle (P14, p.70).** The live session's tool list and instructions are emissions, not state:
  after each reconcile the host notifies once, and the app sends one `session.update`, never a "revert".

## 3. Self-configuration: proposals (P9, P10, P11)

The assistant changes itself only through proposals. A proposal is a list of operations on the tree:

```json
{"summary": "Remember that standup is at 10", "changes": [
  {"op": "append", "path": "memory.facts", "value": "Standup is at 10:00"}]}
```

Operations: `set` (a field), `append` / `removeValue` (array items), `addEntry`, `removeEntry`. Paths name an
entry id then a key: `identity.personality`, `settings.voice`, `skill.start-my-day` (for add/remove).

1. **Validate**: only proposable paths (§1); values of the right type; skill entries well formed (1–20 steps, every
   action offered by a harness, none of the actions that always need a spoken yes).
2. **Dry run in isolation (P11, p.19)**: reconcile a copy of the host to the proposed tree. If any changed entry
   would be *failed*, the proposal is refused with the error and the live state is untouched.
3. **Ask**: the gate (`ConfirmGate`) arms the exact proposal; the tool answers CONFIRMATION REQUIRED and the voice
   asks in one sentence. Every proposal needs the human's own yes, typed or spoken, even when the human asked for the
   change; a yes given earlier, or for another proposal, never counts.
4. **Apply transactionally (P10, p.69)**: back up the tree, reconcile the live host, persist; on any failure restore
   the backup. Log the change (id, summary, before, after, time, by assistant or user).
5. **Revert**: `revert_change` proposes going back to a change's `before` tree, through the same gate.

Tools the voice gets for itself (always offered):

| Tool | What it does |
|---|---|
| `describe_self` | its identity, memory, settings, harnesses (with status) and learned skills |
| `propose_change` | any proposal (above) |
| `learn_skill` | a proposal that adds a skill entry: steps (a procedure) and/or a playbook (how to do it) |
| `forget_skill` | a proposal that removes a skill entry |
| `remember` | a proposal that appends a memory fact |
| `revert_change`, `list_changes` | undo a logged change; list them |
| `use_skill` | load a learned skill or a harness's controls into the session (not a change). For a skill it also loads the actions of every harness it `needs`, and its answer *includes the skill's playbook text*, so the voice reads how to do the task (Claude Code's Skill pattern) |

The human's UI edits (identity, memory, toggles, deleting a skill, revert) apply directly and are logged as by user.

## 4. The new hire

- **Identity** (proposable): name, role ("a newly hired personal assistant on the user's Mac"), personality
  (eager, humble, concise), and learned `instructions` (how this human likes things done).
- **Instructions sent to the voice** = fixed rules (speaking, safety, confirmation; human-owned, never proposable)
  + identity + memory facts + "what I can control" (harness catalog) + "what I know" (skills) + how to learn and
  self-improve: when the human teaches a task, learn it; when corrected, or when a change would make it better,
  propose it in one sentence and wait for a yes.
- **First session ever** (no skills, no memory): the greeting says it is new, can only control the harnesses it
  names, doesn't know how the human works yet, and asks for its first task.
- Changing identity or memory updates the live session's instructions: a new `WireCommand.updateInstructions`
  (OpenAI `session.update {session: {type: realtime, instructions}}`, Grok `{session: {instructions}}`; Gemini and
  Local send nothing) and `Realtime.setInstructions(_:)`, which sends it where tools are dynamic and otherwise renews
  the connection (the recap carries the conversation).
- Every proposal needs a yes, even "remember my standup is at 10": two turns instead of one. That is deliberate for
  0.2; a "low-risk changes apply at once" tier is a later tuning knob.

## 5. Routing

Before anything is routed, every available harness's controls are loaded: the new hire knows its controls from the
first turn. Jev's choice is over: learned skills, each available harness ("raw controls"), and `chat`. A learned skill loads its
procedure tool and its harnesses' actions; a harness loads its actions. Without a Jev key, word matching. The voice
can always `use_skill`.

## 6. Checks (paper §5, as property tests)

- **Recovery** (Cor. 69, p.46): learning then forgetting a skill leaves the tool list and catalog identical.
- **Confluence** (Thm. 80, p.54): random sequences of add/remove/disable/enable/config changes settle where a fresh
  load of the final tree does.
- **Ordering** (Thm. 70–71, p.47): no skill is active while a harness it needs is off.
- **Containment** (p.56): a failing entry leaves every other entry's state unchanged.
- **Governance**: no proposal applies without a yes; human-owned paths can't be proposed; a refused dry run leaves
  live state untouched; revert restores the earlier tree.
- **Growth** (this app's own metrics): skills taught, replays and replay failures, proposals applied and reverted;
  shown in the app.
