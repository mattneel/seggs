# Seggs Product and System Specification

**Document status:** Proposed implementation specification  
**Specification version:** 2.0-draft  
**Product target:** Seggs next-generation architecture  
**Technical baseline:** Zig 0.17.0, SDL3, SDL3 GPU, SDL_ttf, Yoga, QuickJS-NG, and ACP v1  
**Replaces:** The slot-based agent model and the original eight-agent interaction contract  
**Source baseline:** The current Seggs README and the verified native scaffold

## 1. Product definition

Seggs is a GPU-native programmable workbench for software development. It combines code, developer tools, coding agents, and human decisions in inspectable workflows.

The editor is the primary work environment. Composition is the primary product distinction.

Seggs treats agents as execution resources. It does not treat agents as permanent interface panels or numbered slots.

Seggs lets a developer select any useful artifact and pipe it into an agent, command, workflow, comparison, or human gate.

The primary product promise is:

> A developer can compose a team, inspect its work, and accept a tested change within one native code workspace.

## 2. Current foundation

The existing implementation provides the following foundations:

- A native shell with fullscreen and windowed modes.
- A direct SDL3 GPU renderer with batched textured quads.
- An SDL_ttf glyph atlas with fallback faces.
- A UTF-8 editor buffer with selection, clipboard, undo, and redo.
- A Yoga layout boundary.
- A QuickJS-NG extension host for SeggsC.
- An ACP client with sessions, prompts, updates, permissions, and cancellation.
- Oh-My-Pi, Codex ACP, Claude ACP, custom ACP, and mock presets.
- Language server, debug adapter, Git, worktree, and PTY services.
- Native tests, transport tests, fixture tests, and screenshot gates.

This specification preserves those foundations. It changes the product model, execution model, and interface architecture above them.

## 3. Goals

Seggs 2.0 must meet these goals:

1. Remove every fixed product limit on profiles, sessions, workflows, and runs.
2. Compose agents and tools through typed artifacts.
3. Isolate independent write branches through candidate workspaces.
4. Make every prompt destination explicit before submission.
5. Connect every accepted change to its source snapshot and test evidence.
6. Keep the editor responsive during high agent activity.
7. Expose one execution engine through the interface, workflow files, SeggsC, and the CLI.
8. Preserve honest capability and security labels.
9. Recover documents and durable run state after a crash.
10. Support keyboard, pointer, text input, accessibility, and display scale requirements.

## 4. Non-goals for the first push

The first composition release does not include these features:

- A cloud control plane.
- A workflow marketplace.
- Remote team collaboration.
- A new general-purpose scripting language.
- Full VS Code feature parity.
- A mandatory graph for every workflow.
- Token-by-token pipes between agents.
- Automatic trust for workspace workflow files.
- A claim that Git worktrees provide operating-system isolation.
- Background run survival after application exit.

These exclusions protect the first vertical slice. They do not prohibit later work.

## 5. Product principles

### 5.1 Work before infrastructure

The interface must organize user work by task and run. Agent harness names provide secondary context.

### 5.2 Code remains central

The editor must retain the largest default surface. Orchestration must appear near the code and evidence that it affects.

### 5.3 Everything useful is pipeable

A selection, diagnostic, command result, patch, review, plan, file, symbol, or prior artifact can become workflow input.

### 5.4 Evidence outranks claims

An agent report cannot replace command evidence. ACP turn completion cannot establish task success.

### 5.5 Decisions scale better than chats

The interface must prioritize permissions, conflicts, failures, and reviews. It must not require one visible chat panel per session.

### 5.6 Native precision

The interface must retain square geometry, thin separators, dense information, graphite surfaces, and restrained mint accents.

### 5.7 Honest boundaries

Seggs must not label a process as restricted unless an execution boundary enforces that restriction.

## 6. Core domain model

Every core object must use a stable opaque identifier. UI positions and array indices must never act as identities.

| Object | Definition | Durable |
| --- | --- | --- |
| Workspace | An opened project root and its editor state. | Yes |
| Agent profile | A reusable ACP harness configuration and execution policy. | Yes |
| Connection | One live adapter process or transport connection. | No |
| Session | One conversation with one agent profile. | Yes |
| Workflow | A versioned definition of steps and connections. | Yes |
| Workflow revision | An immutable workflow snapshot. | Yes |
| Run | One workflow revision with captured inputs and policy. | Yes |
| Step | One invocation of an agent, command, transform, gate, or service. | Yes |
| Step attempt | One execution attempt for a step. | Yes |
| Artifact | An immutable typed input or result. | Yes |
| Candidate workspace | An isolated checkout for proposed changes. | Yes |
| Decision | A scoped request for human authority or judgment. | Yes |
| Evidence | An artifact that records an observed command or validation result. | Yes |

### 6.1 Identity rules

- IDs must remain unique across process restarts.
- Deleted IDs must never return to the active namespace.
- Late events must retain their original session and run identity.
- Numeric shortcuts can select favorites. They must not select array positions.
- A session can exist without a visible panel.
- A run can exist without an active session.
- A workflow can invoke one profile more than once.
- Each invocation receives an independent session unless the workflow requests reuse.

### 6.2 Agent profile

An agent profile contains these fields:

```text
AgentProfile
  id
  display_name
  adapter_kind
  argv
  default_cwd_policy
  environment_policy
  authentication_status
  capability_cache
  process_reuse_policy
  resource_class
  favorite_rank?
  created_at
  updated_at
```

The profile registry must use dynamic storage. Profile count must not determine process count.

### 6.3 Session

A session contains conversation identity and protocol state. A connection only supplies transport.

```text
Session
  id
  profile_id
  run_id?
  step_id?
  remote_session_id?
  lifecycle_state
  capability_snapshot
  transcript_ref
  created_at
  last_activity_at
```

Session restoration depends on adapter support. The interface must explain unavailable restoration.

### 6.4 Run

A run captures one exact workflow revision and one exact input bundle.

```text
Run
  id
  title
  workflow_revision_id
  workspace_id
  source_snapshot_id
  policy_snapshot
  state
  created_at
  started_at?
  completed_at?
  interrupted_reason?
```

The workflow definition cannot change an existing run. A new workflow revision applies only to a new run.

## 7. Workflow execution model

Seggs owns composition above ACP. ACP transports agent protocol messages and does not define workflow pipes.

### 7.1 Required step types

| Step type | Required behavior |
| --- | --- |
| Context | Capture selected source, diagnostics, files, symbols, or prior artifacts. |
| Agent | Invoke one agent session with an explicit prompt and input bundle. |
| Command | Execute an argv array in a declared workspace. |
| Transform | Convert artifacts through a deterministic core or extension function. |
| Service | Invoke LSP, DAP, Git, worktree, or PTY services. |
| Human gate | Wait for one scoped human decision. |
| Apply | Apply selected candidate changes to the developer workspace. |
| Workflow | Invoke a saved workflow through its declared contract. |

Shell command steps must store argv arrays. They must not require shell-string interpolation.

### 7.2 Composition primitives

| Primitive | Contract |
| --- | --- |
| Pipe | A downstream step receives a complete schema-valid artifact bundle. |
| Fork | Independent branches receive the same immutable input snapshot. |
| Join | A step waits for its declared upstream result set. |
| Map | The scheduler applies a step to each item in a collection. |
| Branch | A declared condition selects one path from an artifact value. |
| Human gate | The run pauses until a scoped decision exists. |
| Retry | A new attempt starts under an explicit policy and limit. |
| Repair | A declared step receives failure evidence from another step. |
| Compare | A view or step aligns several candidate results and their evidence. |

### 7.3 Pipe semantics

A pipe transfers completed artifacts. It does not transfer raw ACP stdout or partial JSON-RPC messages.

Live progress uses a separate event channel. Progress events cannot satisfy an artifact dependency.

The runtime must verify artifact schemas before downstream admission. A schema failure must create an explicit failed step.

Each downstream step must declare required and optional inputs. The scheduler must reject a run with an impossible connection.

### 7.4 Failure semantics

Each step ends in one terminal state:

```text
succeeded
failed
cancelled
skipped
interrupted
```

`succeeded` means that the step produced its declared outputs. It does not mean that a human accepted the result.

A failed dependency blocks a downstream step by default. A workflow can route failure artifacts into a declared repair branch.

A retry creates a new attempt. It never erases the prior attempt.

External side effects require an idempotency policy. Seggs must never repeat an unknown side effect without a new decision.

### 7.5 Cancellation semantics

Cancellation targets a run, branch, step, attempt, session, or command. The target must remain visible in the decision surface.

A cancelled step cannot produce new accepted outputs. Late transport events become retained diagnostic events.

Cancellation must propagate to dependent steps. Independent branches must continue unless the request includes them.

The runtime must preserve access to partial output. Partial output must carry an incomplete label.

### 7.6 First canonical workflow

```text
context @selection @diagnostics
  | agent oh-my-pi "Produce an implementation plan"
  | agent codex "Implement the plan in a candidate workspace"
  | command ["zig", "build", "test"]
  | agent claude-code "Review the patch and test evidence"
  | human-approval
  | apply
```

The implementation step produces a patch in a candidate workspace. The command tests that exact candidate tree.

The review step receives the patch and command evidence. The apply step requires a separate human decision.

## 8. Artifact contract

Artifacts are immutable and content-addressed where practical. Metadata changes create a new artifact record.

### 8.1 Common envelope

```text
Artifact
  id
  type
  schema_version
  content_ref
  content_digest
  source_run_id
  source_step_id
  source_attempt_id
  source_snapshot_id?
  candidate_workspace_id?
  trust_class
  completeness
  created_at
  parent_artifact_ids[]
```

### 8.2 Required artifact types

| Type | Purpose |
| --- | --- |
| `source.selection` | A source range with path, revision, and text snapshot. |
| `source.file` | A file snapshot with path and digest. |
| `source.symbol` | A symbol reference with language server identity. |
| `diagnostics.set` | Diagnostics with document revisions. |
| `agent.message` | Selected agent output with protocol provenance. |
| `plan.document` | A structured or textual implementation plan. |
| `patch.set` | A multi-file candidate change set. |
| `command.result` | Argv, environment policy, exit code, output, and duration. |
| `test.result` | Test command evidence for one candidate tree digest. |
| `review.report` | Findings linked to files, hunks, and evidence. |
| `decision.record` | A human decision with scope and actor. |
| `workspace.snapshot` | A source baseline with document and repository state. |
| `collection` | An ordered set of artifact references. |

### 8.3 Trust classes

Each artifact uses one trust class:

```text
user-authored
workspace-observed
command-observed
agent-claimed
extension-produced
derived
```

The UI must distinguish command evidence from agent claims. It must not use color as the only distinction.

### 8.4 Context capture

Prompt context must use captured artifacts. It must not use invisible live references.

A context preview must expose every automatic addition. The user can remove each optional addition.

A document change after capture marks the context as stale. Seggs must not replace the captured version silently.

Unsaved buffers require explicit snapshot metadata. A file path alone cannot represent an unsaved buffer.

## 9. Scheduler and concurrency

Seggs has no fixed product limit on profiles, sessions, runs, or workflow width. Resource policies still control active execution.

### 9.1 Admission

The scheduler must consider these resources:

- Process count.
- CPU load.
- Memory use.
- Storage budget.
- Provider limits.
- User budgets.
- Candidate workspace count.
- Per-profile concurrency rules.

A queued step must display its queue reason. Hidden global ceilings are not permitted.

### 9.2 Fairness

The scheduler must prevent one run from permanent queue domination. Interactive work receives a documented priority class.

Cancellation and permission responses must bypass ordinary output backpressure. A full transcript queue cannot block control traffic.

### 9.3 Scale behavior

Historical run count must not increase active per-frame work. The interface must virtualize large lists and transcripts.

Profile restoration must not start harness processes. A process starts only for an admitted step or an explicit user action.

Memory queues must remain bounded. Durable storage must absorb eligible history under a visible retention policy.

### 9.4 Usage

Usage values must identify their source as reported or estimated. Missing cost data must appear as `Unknown`.

## 10. ACP adapter contract

The ACP layer remains a versioned transport boundary. Product views must not depend on raw wire structures.

### 10.1 First-class integrations

Seggs must provide first-class setup and conformance coverage for:

- Oh-My-Pi through `omp acp`.
- Codex through the Codex ACP adapter.
- Claude Code through the Claude ACP adapter.
- Custom ACP v1 stdio harnesses.
- The local deterministic mock.

First-class status does not grant scheduler privilege.

### 10.2 Capability negotiation

The adapter must cache a capability snapshot per session. Unsupported controls must remain unavailable with an explanation.

The UI must not expose generic protocol pause when the adapter lacks pause support. The scheduler can offer `Pause after this step`.

### 10.3 Process reuse

The runtime must separate connections from sessions. A process can host several sessions only after adapter conformance tests pass.

The default policy uses one process per active session when safe reuse is unknown. Process reuse must never merge conversation state.

### 10.4 Framing and transport

The transport must preserve fragmented reads, short writes, bounded frames, cancellation, and clean process teardown.

Raw ACP events remain available for diagnostics. They do not form the default run interface.

## 11. Candidate workspace model

Every independent write branch receives a separate candidate workspace by default. Sequential steps can share one candidate workspace.

### 11.1 Workspace identity

```text
CandidateWorkspace
  id
  run_id
  branch_id
  source_snapshot_id
  repository_root
  worktree_path
  head_revision
  dirty_state
  tree_digest
  lifecycle_state
```

### 11.2 Isolation claims

A Git worktree provides a separate checkout. It does not provide process, filesystem, network, or repository-object isolation.

The interface must display the enforced execution boundary. It must label unrestricted processes honestly.

### 11.3 Candidate lens

The editor can show a read-only file from a candidate workspace. The active developer checkout must not change.

Candidate content requires a persistent label. Pointer or keyboard focus cannot convert the preview into an active workspace silently.

### 11.4 Apply service

The apply service must compare source revisions before each workspace mutation. It must preserve unsaved buffers.

The service must write a recovery journal before a multi-file apply. It must expose conflicts as review items.

Partial hunk acceptance creates a new candidate result. Prior test evidence must become stale for the modified result.

Seggs must offer tests against the final accepted tree before commit.

## 12. Workbench interface

The permanent agent sidebar is removed. A contextual Inspector replaces it.

### 12.1 Application shell

The default shell contains these regions:

| Region | Purpose | Default behavior |
| --- | --- | --- |
| Top bar | Project, worktree, perspective, decisions, global actions. | Always visible. |
| Activity rail | Files, Search, Runs, Source Control, Extensions. | Compact and persistent. |
| Left dock | Source navigation or run navigation. | Resizable and collapsible. |
| Center | Editor, workflow, or review surface. | Dominant surface. |
| Inspector | Context for selection, run, artifact, or review. | Resizable and collapsible. |
| Bottom dock | Terminal, diagnostics, tests, and logs. | Collapsible. |
| Status bar | Branch, candidate, language, position, and background state. | Always visible. |

The activity rail must not include a permanent Agents item. Harness management belongs in Settings and the command palette.

### 12.2 Perspectives

Seggs provides four perspectives on one shared workspace state:

| Perspective | Primary surface | Primary question |
| --- | --- | --- |
| Code | Editor groups and contextual actions. | What needs a change? |
| Runs | Run history, progress, and decisions. | What work exists now? |
| Compose | Workflow sequence or graph. | How will this work happen? |
| Review | Candidate changes and evidence. | What can I accept? |

A perspective change must preserve selected file, run, artifact, and navigation history where relevant.

### 12.3 Default geometry

The initial desktop layout uses these prototype values:

| Element | Initial value |
| --- | --- |
| Interface text | 13 to 14 logical pixels. |
| Editor text | 14 to 16 logical pixels. |
| Navigation row | 26 to 30 logical pixels. |
| Left dock width | 220 to 260 logical pixels. |
| Inspector width | 300 to 380 logical pixels. |
| Spacing scale | 4 and 8 logical pixels. |

These values are defaults, not fixed limits. Editor zoom must not resize all interface controls.

### 12.4 Responsive behavior

Each dock supports resize, collapse, and saved placement. Small windows use temporary drawers instead of narrow unreadable panels.

The renderer must distinguish window coordinates, drawable pixels, and display scale. Pointer targets must align after scale changes.

### 12.5 Source navigator

The source navigator must provide a collapsible directory tree. Generated content stays hidden through visible exclusion rules.

The navigator must support breadcrumbs, a symbol outline, Git decorations, and run decorations. Search can include excluded content through an explicit option.

A row must distinguish these states:

- Unsaved buffer.
- File change on disk.
- Git modification.
- Candidate modification from a run.
- Conflict.

The current worktree must remain visible above the tree.

### 12.6 Editor groups

The Code perspective must support multiple buffers, tabs, and split groups. Each group retains independent navigation history.

Candidate previews and editable documents must use distinct persistent labels. The editor must never confuse their mutation targets.

### 12.7 Inspector

The Inspector changes with selection context:

- A code selection shows symbol data, diagnostics, attachments, and `Pipe to…` actions.
- An active run shows its steps, state, current agent, queue reason, and controls.
- A completed candidate shows patch size, tests, review findings, and review actions.
- A workflow step shows inputs, outputs, policy, profile, and attempts.
- A terminal command shows exit state, captured output, and pipe actions.

The Inspector must not steal editor focus when new events arrive.

### 12.8 Run navigator

The run navigator groups work by task and workspace. Each row exposes current state, current step, and required decision.

Decision requests appear before routine progress. Completed work moves into searchable history unless the user pins it.

The harness name appears as secondary information. A token event must not reorder run rows.

### 12.9 Decision inbox

The decision inbox contains these items:

- Permission requests.
- Human gates.
- Patch review requests.
- Apply conflicts.
- Recoverable failures.

Each decision must show the run, step, requested scope, and consequences. One decision cannot authorize another run.

Seggs must not include a global approval command. Keyboard navigation can support rapid individual decisions.

## 13. Composer and pipe interaction

The permanent `Ask this agent…` box is removed. A contextual composer appears through an action, command, or workflow step.

### 13.1 Composer requirements

The composer must provide:

- Multiline text.
- Full cursor movement.
- Selection.
- Undo and redo.
- Draft history.
- Draft persistence.
- Context chips.
- File and symbol references.
- Prompt templates.
- Agent or workflow destination.
- Candidate workspace policy.
- Queue state.
- A complete context preview.

The destination must remain visible above the input. A sidebar selection cannot redirect an existing draft.

Submission must capture the destination identity before asynchronous work starts.

### 13.2 Actions

The composer distinguishes these actions:

```text
Send to session
Start new run
Run workflow
Queue after current turn
```

A busy session must expose its prompt queue. The interface must not claim that a queued prompt reached the active turn.

### 13.3 Pipe to

`Pipe to…` is the signature Seggs action. It must exist in the editor, terminal, diagnostics, artifact view, diff view, and run inspector.

The destination menu shows compatible targets only:

```text
Oh-My-Pi
Codex
Claude Code
Saved workflow…
New pipeline…
Command…
Compare…
```

The preview must show captured input and the proposed next step. It must identify stale context before execution.

### 13.4 Pipeline strip

A linear workflow uses a compact editable strip by default:

```text
Selection │ Oh-My-Pi │ Codex │ Test │ Claude │ Review
```

The user can inspect any stage. The user can reorder stages only when schemas and dependencies remain valid.

A graph view appears when branches improve comprehension. A graph is not the default for a linear workflow.

## 14. Terminal integration

The terminal remains a real PTY. Seggs must not replace ordinary terminal output with cards.

Seggs can recognize command boundaries from client-owned terminals. A completed command can produce a `command.result` artifact.

The terminal can expose these actions at known command boundaries:

```text
Attach
Pipe to…
Create fix run
Save as evidence
```

Captured output must identify its byte range and command. Secret redaction remains an explicit user or policy action.

A workflow command step uses a separate execution record. It can still stream output into a terminal view.

## 15. Review perspective

Review is a first-class workspace. It must not require transcript inspection for ordinary approval.

### 15.1 Change model

The Review perspective shows:

- A multi-file change set.
- File and hunk navigation.
- Source step provenance.
- Source snapshot identity.
- Candidate workspace identity.
- Command and test evidence.
- Review findings.
- Conflict state.
- Hunk acceptance state.

### 15.2 Three trees

Review must keep these trees distinct:

1. The source snapshot for the run.
2. The candidate result from the run.
3. The current developer workspace with unsaved buffers.

A changed developer baseline creates a visible conflict state. Seggs must never disguise a candidate preview as an editable developer buffer.

### 15.3 Review actions

The developer can perform these actions:

```text
Accept hunk
Reject hunk
Accept file
Reject file
Request revision
Run tests
Compare candidate
Apply selected changes
Discard candidate
```

A revision request creates a follow-up step with selected changes and findings as context.

Acceptance of a patch does not grant permission to commit, push, publish, or deploy.

## 16. Visual system and component architecture

The interface retains the existing graphite and mint identity. The redesign refines hierarchy without a decorative card style.

### 16.1 Visual rules

- Use square or lightly softened geometry.
- Use thin separators for structural boundaries.
- Use luminance and spacing before containers.
- Use proportional text for interface labels.
- Use monospace text for code and command output.
- Use mint for focus, identity, and primary actions.
- Use motion only for state continuity and intentional progress.
- Never use color as the sole status signal.

### 16.2 Core component set

The native component system must provide:

- Button, icon button, toggle, and segmented control.
- Text field, composer, search field, and command field.
- Menu, context menu, popover, and dialog.
- Tree, virtual list, table, and breadcrumb.
- Tab strip, split view, dock, drawer, and inspector section.
- Status badge, progress row, decision row, and run row.
- Diff view, hunk control, evidence row, and artifact chip.
- Pipeline strip, workflow step, port, branch, and connection.
- Terminal host and command boundary action.
- Tooltip, notification, and inline error.

### 16.3 Component contract

Each component must define:

- Focus behavior.
- Keyboard behavior.
- Pointer behavior.
- Disabled behavior.
- Scale behavior.
- Semantic role.
- Accessible name and state.
- High-contrast behavior.
- Reduced-motion behavior.
- Visual test states.

The component gallery is a release gate. Product surfaces must use gallery components instead of local substitutes.

## 17. Command system

Seggs remains command-first. Every major action must have one command identity.

Required commands include:

```text
Files: Focus
Search: Focus
Runs: Focus
Run: New
Run: Cancel
Run: Continue from Artifact
Workflow: Run
Workflow: Save Current Sequence
Pipe: Selection
Pipe: Terminal Command
Review: Open
Review: Apply Selected
Candidate: Compare
Candidate: Open Lens
Context: Attach Selection
Context: Attach Diagnostics
Harness: Manage Profiles
```

Menus, shortcuts, the command palette, and SeggsC actions must invoke the same command registry.

Keyboard shortcuts must bind commands, not UI positions. User configuration can replace default bindings.

## 18. SeggsC extension contract

SeggsC remains the declarative TypeScript-shaped extension layer. Zig remains the authority for safety-critical state and mutations.

### 18.1 Extension contributions

An extension can contribute:

- Commands.
- Context providers.
- Artifact renderers.
- Inspector sections.
- Workflow step types.
- Workflow templates.
- Run actions.
- Review annotations.
- Language-specific context adapters.

### 18.2 Core authority

The Zig core owns these functions:

- Process creation and termination.
- ACP transport.
- Permission decisions.
- Workflow scheduling.
- Artifact identity and storage.
- Document transactions.
- Candidate workspace lifecycle.
- Apply operations.
- Policy enforcement.
- Durable run records.

An extension request crosses the same permission boundary as a built-in request.

### 18.3 Containment

A QuickJS context does not provide an operating-system sandbox. Seggs must describe that boundary accurately.

The host must enforce execution budgets and memory budgets. An extension failure cannot block the UI event loop indefinitely.

Imported workflow steps require trust before executable actions start.

## 19. Workflow files

Saved workflows live under `.seggs/workflows/`. The first stable format uses versioned JSON or JSON-compatible data.

The text view and visual view must edit one canonical definition. Neither view can store an independent graph.

### 19.1 Minimal example

```json
{
  "schema": "seggs.workflow/v1",
  "id": "plan-implement-review",
  "name": "Plan, implement, test, review",
  "inputs": {
    "context": { "type": "source.selection" }
  },
  "steps": [
    {
      "id": "plan",
      "type": "agent",
      "profile": "oh-my-pi",
      "prompt": "Produce an implementation plan",
      "in": { "context": "$inputs.context" },
      "out": { "plan": "plan.document" }
    },
    {
      "id": "implement",
      "type": "agent",
      "profile": "codex",
      "workspace": "candidate",
      "prompt": "Implement the plan",
      "in": { "plan": "$steps.plan.plan" },
      "out": { "patch": "patch.set" }
    },
    {
      "id": "test",
      "type": "command",
      "argv": ["zig", "build", "test"],
      "workspace": "$steps.implement.workspace",
      "out": { "result": "test.result" }
    },
    {
      "id": "review",
      "type": "agent",
      "profile": "claude-code",
      "prompt": "Review the patch and test evidence",
      "in": {
        "patch": "$steps.implement.patch",
        "tests": "$steps.test.result"
      },
      "out": { "report": "review.report" }
    },
    {
      "id": "approval",
      "type": "human_gate",
      "in": {
        "patch": "$steps.implement.patch",
        "tests": "$steps.test.result",
        "review": "$steps.review.report"
      }
    },
    {
      "id": "apply",
      "type": "apply",
      "in": {
        "patch": "$steps.implement.patch",
        "decision": "$steps.approval.decision"
      }
    }
  ]
}
```

### 19.2 Validation

The loader must reject unknown schema versions. It must report incompatible ports before run creation.

The loader must report missing profiles as setup actions. It must not defer obvious dependency failures until execution.

Workspace workflow files remain untrusted until the user grants trust. Trust applies to one content digest or an explicit policy scope.

## 20. CLI contract

The public `seggs` CLI uses the same execution engine as the interface.

### 20.1 Agent command

```sh
git diff -- src/ \
  | seggs agent run claude-code --task "Review this diff" --output text \
  | tee review.md
```

Selected result content goes to stdout. Progress and diagnostics go to stderr.

### 20.2 Workflow command

```sh
seggs workflow run .seggs/workflows/plan-implement-review.json \
  --input context=@selection.json \
  --output jsonl
```

Structured output uses versioned JSONL artifact records. Exit status must reflect final run state.

A noninteractive run must fail closed when it requires an unavailable decision. It must not wait for an invisible dialog.

## 21. Persistence and recovery

The execution engine must not depend on an open panel. Panel closure cannot cancel work.

Durable state must include:

- Profiles and profile metadata.
- Workflow definitions and revisions.
- Runs, steps, and attempts.
- Artifact metadata and durable content references.
- Decisions.
- Candidate workspace records.
- Transcript references.
- UI layouts and navigation state.
- Draft composers.

### 21.1 Crash recovery

After restart, Seggs must mark uncertain active work as interrupted. It must not claim exactly-once completion.

Recovered runs must expose the last durable event and possible side effects. The user can inspect, retry, or abandon each run.

Document recovery and run recovery use separate journals. A failed run recovery cannot erase a document recovery record.

### 21.2 Retention

The user must see retention rules for transcripts, artifacts, logs, and candidate workspaces. Budget exhaustion must create a visible state.

Seggs must not delete the only copy of an unapplied candidate without an explicit policy or decision.

## 22. Permissions, policy, and security

Permissions are scoped decisions. Workflow structure cannot grant future tool authority.

### 22.1 Decision scope

A permission record identifies:

- The run.
- The step and attempt.
- The requesting session.
- The command or resource.
- The requested capability.
- The workspace.
- The decision.
- The actor.
- The expiration.

An approval for one attempt cannot authorize another attempt unless the scope states that rule explicitly.

### 22.2 Security labels

Seggs can display labels such as:

```text
Unrestricted process
Separate Git worktree
Client-approved ACP tools only
Network restricted by external sandbox
Read-only filesystem enforced externally
```

The interface must derive each label from an enforced boundary or a recorded fact.

### 22.3 Secrets

Seggs must not store secrets in workflow defaults. Environment policies must use references to configured secret sources.

Context preview must identify likely secret content when a detector produces a finding. The user retains the final decision.

### 22.4 Apply authority

Patch acceptance does not grant Git commit, push, release, or deployment authority. Each external side effect requires its own policy.

## 23. Accessibility and text

The interface must support keyboard-only operation for all release paths. Focus order must remain visible and deterministic.

The text system must support grapheme-aware navigation, selection, and deletion. It must support IME composition.

Native accessibility bridges must expose semantic roles, names, values, state, and focus. Shortcut documentation cannot replace semantic access.

High-contrast themes and reduced-motion behavior are release requirements. Color cannot be the only carrier of meaning.

## 24. Performance requirements

Performance results require named hardware and reproducible workloads. The first acceptance targets are:

| Area | Target |
| --- | --- |
| Input response | The p95 local input-to-visible-update time remains below 50 ms. |
| Frame delivery | The p95 visible frame time remains below 16.7 ms on declared 60 Hz hardware. |
| Idle use | The renderer sleeps without input, invalidation, or intentional animation. |
| Active sessions | A 100-session mock workload leaves code input responsive. |
| History | 10,000 historical runs do not create per-frame history scans. |
| Profile restore | 1,000 profiles restore without automatic process launches. |
| Event rate | The mock supports 20 updates per session per second with permission bursts. |

These numbers are test points. They are not product limits.

## 25. Observability

Every run must expose a structured event history. Each event includes run, step, attempt, and source identity.

The diagnostics view must distinguish these sources:

- Core scheduler.
- ACP adapter.
- Harness stderr.
- Workflow command.
- Extension host.
- Candidate workspace service.
- Apply service.

The UI must never invent progress from absent events. Unknown state must remain unknown.

## 26. Migration from the current implementation

The migration preserves working services while it replaces slot-based ownership.

### Phase M0: Identity seam

1. Add stable IDs for profiles, sessions, runs, steps, and artifacts.
2. Wrap current agent slots behind the new registry.
3. Move command routing from indices to IDs.
4. Preserve compatibility with current configuration files.
5. Add a migration warning for numbered shortcuts.

Exit gate: The ninth profile behaves like the first profile.

### Phase M1: Run seam

1. Add durable run and artifact stores.
2. Route current transcript events into one run timeline.
3. Keep raw ACP diagnostics available.
4. Add explicit composer destination identity.
5. Replace broadcast semantics with named multi-destination run creation.

Exit gate: No late event can enter another session after deletion or restart.

### Phase M2: Workbench seam

1. Replace the Agents panel with the contextual Inspector.
2. Add Files, Search, Runs, Source Control, and Extensions to the activity rail.
3. Add the native component gallery.
4. Add the real source tree.
5. Add tabs, splits, and saved dock layouts.

Exit gate: A user can identify a prompt destination from the composer alone.

### Phase M3: Composition seam

1. Add typed artifacts and schema validation.
2. Add agent, command, human gate, and apply steps.
3. Connect the existing worktree service to candidate creation.
4. Add a native diff surface with provenance.
5. Add the local end-to-end mock workflow.

Exit gate: Two agents exchange an immutable artifact without transcript copy and paste.

## 27. Release roadmap

### R0: Contract reset

R0 removes the fixed agent architecture. It adds stable identity, dynamic storage, and the component gallery.

Exit gates:

- The ninth agent behaves like the first.
- A 1,000-profile fixture restores without 1,000 processes.
- Deleted session IDs cannot receive late active events.
- Zig 0.17.0 remains the declared build target.

### R1: Workbench UI 2.0

R1 adds the dock system, source tree, contextual Inspector, command system, and full composer.

Exit gates:

- Four of five new test users identify the prompt destination without help.
- A keyboard path covers file selection, context attachment, and submission.
- Display scale changes preserve clipping and pointer targets.
- The editor remains the dominant default surface.

### R2: Orchestration vertical slice

R2 adds sequential workflows, typed artifacts, candidate workspaces, tests, Review, and apply.

Exit gates:

- Oh-My-Pi produces a plan.
- Codex implements the plan in a candidate workspace.
- `zig build test` evaluates that exact candidate tree.
- Claude Code receives the patch and test evidence.
- The developer accepts selected hunks in Review.
- No transcript copy and paste occurs.
- A failed test cannot become a successful run.

### R3: Parallel execution

R3 adds fork, join, map, comparison, scheduler pressure, and the decision inbox.

Exit gates:

- Three candidates start from one immutable snapshot.
- Every candidate receives the same declared tests.
- Cancellation blocks stale later application.
- A 100-session mock workload leaves editor input responsive.

### R4: Programmable Seggs

R4 adds saved workflow files, nested workflows, the public CLI, and SeggsC workflow contributions.

Exit gates:

- One workflow runs through the interface and CLI with equivalent inputs.
- The text and visual editors change one canonical definition.
- Imported executable workflows require trust.
- Stored artifacts remain distinct from new execution.

### R5: Daily-driver baseline

R5 completes the practical editor baseline. It includes search, reliable save behavior, syntax support, LSP completion, rename, and a usable PTY.

Exit gates:

- A developer completes a normal project task without another editor.
- Crash recovery preserves documents and run records.
- Supported platforms pass the native acceptance matrix.
- Accessibility acceptance tests pass on supported platforms.

## 28. First development sprint

The first sprint delivers one coherent product change.

1. Replace slot identity with stable dynamic profile and session IDs.
2. Add durable run, step, attempt, and artifact records.
3. Build the native component gallery.
4. Replace the agent roster with a run-aware Inspector.
5. Add the full composer with explicit destination identity.
6. Connect two mock agent steps through one immutable artifact.
7. Add one candidate workspace and one patch artifact.
8. Add one human gate and one native diff view.

### Sprint demonstration

The developer selects code in the editor. The developer invokes `Pipe to…` and selects the two-agent mock workflow.

The first mock produces a plan artifact. The second mock produces a candidate patch in a separate worktree.

The Review perspective shows the patch, provenance, and source revision. The developer accepts selected hunks through a scoped decision.

This demonstration proves the new runtime and interaction models together.

## 29. Acceptance matrix

| Area | Required proof |
| --- | --- |
| Identity | No profile, session, run, or step uses a UI index as identity. |
| Composition | One cross-harness task completes without transcript copy and paste. |
| Provenance | Every accepted hunk links to its source step and source snapshot. |
| Evidence | Every displayed test result identifies the tested candidate tree. |
| Destination | The composer exposes the exact target before submission. |
| Isolation | Independent write branches use different candidate workspaces. |
| Decisions | One approval cannot authorize another run or attempt. |
| Cancellation | A cancelled branch cannot apply a later stale result. |
| Recovery | A restart marks uncertain active work as interrupted. |
| Scale | Fixture targets pass without fixed product ceilings. |
| Accessibility | Keyboard, focus, semantic, contrast, and IME tests pass. |
| Security | Every restriction label maps to an enforced boundary. |

## 30. Canonical end-state flow

```text
selected code
  │
  ▼
Pipe to Oh-My-Pi
  │
  ▼
plan artifact
  │
  ▼
Pipe to Codex
  │
  ▼
candidate workspace + patch artifact
  │
  ▼
zig build test
  │
  ▼
test evidence
  │
  ▼
Pipe patch + evidence to Claude Code
  │
  ▼
review report
  │
  ▼
native Review perspective
  │
  ▼
human gate
  │
  ▼
apply selected hunks
```

This flow defines the next product milestone. Seggs becomes a programmable operating environment for software agents, with code at its center.
