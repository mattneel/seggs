# Seggs: The Next Push

## Product direction

The next push is not “more agents in a sidebar.”
**Seggs becomes a native code workbench where agents compose, workflows execute, and every change remains inspectable.**

The eight-agent cap was a scaffold shortcut.
It was not part of the original vision, and it does not belong in the next architecture.
The replacement is not a larger array.
It is a product model without agent slots.

The screenshot provides the current visual baseline.
The attached ZIP predates the newer features described in that screenshot.
This roadmap preserves the native GPU foundation and the extension direction.
It does not treat the older archive as an audit of the current branch.

All release scopes, UI specifications, syntax examples, and performance thresholds below are proposals.
They do not describe completed implementation.

## 1. Change the unit of work

The current interface centers on available harnesses.
The next interface centers on the work that the developer wants to complete.

“Codex is ready” becomes secondary information.
“Parser fix needs your review” becomes primary information.
The harness remains visible, but the task supplies the navigation structure.

Zed already documents independent agent threads and worktree isolation.
Those features establish a useful comparison point, not the complete Seggs destination. [1]

**The Seggs distinction is composability with an editor attached to every step.**
A developer can move from a selected symbol to a pipeline, then from its result to a precise code review.
No transcript copy-and-paste is necessary.

### The product vocabulary

| Object | Meaning |
| --- | --- |
| Agent profile | A reusable harness configuration with defaults and an explicit execution policy. |
| Session | One conversation with a harness. Its identity does not depend on a visible panel. |
| Workflow | A reusable definition of connected steps. A single agent invocation is the simplest workflow. |
| Run | One execution of a workflow against specific inputs. |
| Step | One agent invocation, command, transform, or human decision. |
| Artifact | A versioned input or result, such as a patch, report, or source snapshot. |

A workflow can invoke the same harness several times.
Several workflows can share an agent profile.
Their conversation states remain independent.
A run can exist without an open transcript.

Oh-My-Pi, Codex, and Claude Code remain first-class integrations.
First-class means guided setup, clear authentication state, and dedicated regression coverage.
It does not mean privileged behavior inside the scheduler.
Any compatible ACP harness uses the same core contract.

## 2. Rebuild the workbench, not just its colors

**The editor remains the default center of attention.**
Agent activity appears beside the code that it affects.
The interface expands into orchestration only when the developer needs that view.

### A. Three perspectives, one workspace

| Perspective | Central surface | Primary question |
| --- | --- | --- |
| Code | Editor groups with contextual agent actions. | What needs a change? |
| Compose | A workflow with connected steps and inspectable inputs. | How will this work happen? |
| Review | A coherent change set with source-linked evidence. | What do I accept? |

These are perspectives on the same run and workspace.
They are not separate applications with separate navigation histories.
A perspective change preserves the selected file and run.

The default shell has a clear hierarchy:

- The top bar identifies the project and worktree. It also exposes the perspective switch and decision count.
- The left dock provides source navigation or run navigation. It does not force both into a narrow column.
- The center holds the editor, workflow, or change review.
- The right inspector provides details for the selected run or artifact.
- The bottom dock provides terminals, tests, and diagnostic output.

Every dock supports resize, collapse, and saved placement.
Smaller windows use temporary drawers rather than unreadably narrow panels.
The developer can enter a code-only layout without a permanent agent roster.

### B. A deliberate visual language

The target is a precise native desktop tool, not a decorated terminal.
Proportional text serves interface controls.
Monospace text serves code and command output.

Graphite surfaces establish depth through a few distinct layers.
A restrained mint accent identifies focus and primary actions.
Color never carries status without a text or shape alternative.

Initial design targets:

| Element | Proposed initial value |
| --- | --- |
| Interface text | 13–14 logical pixels with separate density controls. |
| Editor text | 14–16 logical pixels with independent zoom. |
| Common spacing | A consistent 4/8-pixel scale. |
| Navigation rows | 26–30 logical pixels in the standard density. |
| Left dock | Approximately 240 logical pixels, with user resize. |
| Inspector | Approximately 380 logical pixels, with user resize. |

These values are prototype inputs, not fixed constraints.
The editor font size must not determine every button dimension.
Long filenames need deliberate truncation and full-path disclosure, not accidental clipping.

SDL distinguishes window coordinates, pixel density, and display scale.
The UI must account for those distinctions across displays. [2]

The native component system needs consistent focus and pointer behavior.
It also needs semantic roles for accessibility.
A visual component gallery can expose these contracts before each feature invents its own controls.

Text shaping, IME support, and grapheme-aware selection belong in this foundation.
Screen-reader support needs a native accessibility bridge, not just keyboard shortcuts.
Reduced motion and high-contrast themes are release requirements.

### C. A real source navigator

The explorer becomes a collapsible directory tree with live updates.
Generated content stays hidden by default through visible exclusion settings.
Search can still include excluded content through an explicit option.

The navigator supports breadcrumbs and a symbol outline.
Its rows distinguish a dirty buffer from a file changed by a run.
The current worktree remains visible above the tree.

The `book/` content in the screenshot illustrates the current hierarchy problem.
The next explorer prioritizes source work.
Generated files remain accessible.

### D. A composer that knows its destination

The composer becomes a small editor with selection and undo.
It supports multiline prompts without an append-only interaction model.
Each draft belongs to a specific run or new-run target.

The destination appears above the input:

```text
Parser fix / Implement / Codex / worktree: parser-fix
```

A sidebar selection never silently redirects an existing draft.
Submission captures the destination identity before any asynchronous work starts.
A multi-recipient action names every recipient and previews the planned runs.

Context appears as inspectable attachments.
A selected symbol carries its source path and document revision.
A test failure carries the command result that produced it.
Unsaved code carries an explicit snapshot marker.

A context preview shows exactly what Seggs will send.
Automatic additions remain visible and removable.
Changes after capture produce a stale-context marker rather than a silent replacement.

The submit action distinguishes `Send to session` from `Run workflow`.
Busy sessions expose a visible prompt queue.
The interface never pretends that a queued message reached an active turn.

**The signature action is `Pipe to…`.**
A code selection can become the input to a saved workflow.
A failed test can become the input to a repair step.
An agent result can become the input to another agent.

The menu offers compatible destinations rather than every installed tool.
A preview exposes the captured input and proposed next step.
The same action exists in the editor, terminal, and artifact inspector.

A successful sequence can become a saved workflow through `Save as workflow`.
Seggs identifies variable inputs before reuse.
It does not silently preserve secrets or stale file references as defaults.

### E. Runs instead of a wall of chats

The run navigator groups work by task and workspace.
Each row exposes its current step and state.
The harness name supplies secondary context.

The default order surfaces decisions before routine progress.
Completed work moves into searchable history.
Pinned runs remain stable.
A token from another run never changes their position.

A run summary answers three questions:

- What is the task?
- What changed or failed?
- What decision does the developer need to make?

The full transcript remains available in the inspector.
It is evidence, not the primary navigation model.
The UI renders visible rows rather than every historical session.

Tool activity uses compact cards with expandable details.
An absent tool event never becomes an invented progress claim.
Agent output never steals editor focus.
Automatic file follow remains an explicit mode.

### F. A decision inbox

The decision inbox collects permission requests and review requests.
Failures with actionable recovery steps also appear there.
Ordinary completion does not create a modal interruption.

Each decision identifies its run and exact scope.
A permission request exposes the command or resource that needs authorization.
A review request opens the relevant changes rather than the end of a transcript.

Decisions remain separate even when their titles match.
One approval never authorizes a different run.
Keyboard navigation supports rapid review without a global “approve everything” shortcut.

**The interface scales through decisions, not through more visible chat panels.**

### G. Review becomes a first-class workspace

The review surface presents a multi-file change set.
Each change links to its source step and source snapshot.
Test evidence identifies the exact candidate tree that the command tested.

The developer can accept a hunk or reject a change set.
A request for revision creates a follow-up step with the selected changes as context.
It does not require a new transcript explanation from scratch.

The review keeps three states distinct:

- The source snapshot that the run used.
- The candidate result from the run.
- The developer’s current workspace and unsaved buffers.

A changed baseline produces a conflict state.
Partial acceptance invalidates test evidence for the original complete candidate.
Seggs offers tests against the final accepted tree before commit.

Approval of a workflow is not approval of every later tool request.
Acceptance of a patch is not permission to push a branch.
The interface keeps those decisions separate.

**A worktree lens keeps parallel candidates close to the code.**
The developer can inspect the current file as it appears in another run’s candidate workspace.
The active checkout does not change.

Candidate previews remain read-only and visibly labeled.
A comparison can show two implementations beside their test evidence.
The interface never disguises a candidate preview as the developer’s editable buffer.

### H. Compose stays approachable

A linear workflow first appears as an editable sequence of steps.
A graph becomes useful when the workflow contains branches.
A giant graph is not the default home screen.

Each connection exposes the artifact that it carries.
A click opens that artifact in the inspector.
The developer can replace an agent profile.
The other steps retain their configuration.

A saved workflow can itself become a step in another workflow.
Its declared inputs and outputs preserve the same composition contract.
Nested workflows do not add permissions.

The same workflow definition drives the text view and visual view.
Neither view stores an independent version of the workflow.
A schema check rejects incompatible step connections before execution.

“Continue from here” starts a new run from selected artifacts.
It does not claim to restore an agent’s private internal state.
“Compare alternatives” starts independent candidates from the same captured baseline.

## 3. Make composition a real execution contract

**Agents become pipeable through Seggs, not through raw ACP stdout.**
ACP uses bidirectional JSON-RPC over stdio.
That stream contains protocol messages, not just an agent’s final text. [3]

Seggs owns the composition layer above ACP.
It converts selected results into the next step’s inputs.
No new ACP method is necessary for a basic cross-agent pipeline.

### The first pipeline

This is proposed Seggs syntax, not an existing command language:

```text
context @selection @diagnostics
  | agent oh-my-pi "Produce an implementation plan"
  | agent codex "Implement the plan in a new worktree"
  | command ["zig", "build", "test"]
  | agent claude-code "Review the patch and test evidence"
  | human-approval
  | apply
```

Each step receives an explicit input bundle.
The command uses the candidate worktree from the implementation step.
The reviewer receives the patch and command evidence, not just an optimistic summary.

Each result retains references to relevant upstream artifacts.
A review report does not accidentally replace the patch that a later apply step needs.
A failed test stops this example before review unless the workflow defines a failure branch.

### Composition semantics

| Primitive | Required behavior |
| --- | --- |
| Pipe | A downstream step receives a completed, schema-checked result. |
| Fork | Independent branches receive the same immutable input snapshot. |
| Join | The workflow declares whether it requires every result or an explicit subset. |
| Map | A workflow applies a step to a collection through the scheduler. |
| Human gate | Execution waits for a scoped developer decision. |
| Retry or repair | The workflow declares its retry policy and a visible termination condition. |

The first version passes completed artifacts between agent steps.
Live progress travels on a separate event channel.
Token-by-token downstream prompts are not the default pipe behavior.

An artifact records its type and source revision.
It also records its source step and trust classification.
A structured-output schema failure produces an explicit step failure.

ACP distinguishes normal turn completion from other stop reasons.
Normal completion describes the conversation turn, not the correctness of a proposed patch. [4]

The workflow therefore separates transport completion from task acceptance.
An agent’s self-report cannot substitute for a test result or human decision.
Upstream agent text cannot grant downstream permissions.
Artifacts enter prompts as source data, not authority to change the execution policy.

### Real shell interoperability

The public CLI eventually exposes the same engine as the UI.
This proposed example exports an agent result as ordinary text:

```sh
git diff -- src/ \
  | seggs agent run claude-code --task "Review this diff" --output text \
  | tee review.md
```

The wrapper handles ACP internally.
Its stdout contains the selected result format.
Its stderr contains progress and diagnostics.
A structured mode exports versioned JSONL artifacts.

A noninteractive run fails closed when it needs an unavailable approval.
It never waits forever for an invisible dialog.
Saved workflows produce the same records from the CLI and the editor.

## 4. Remove agent caps, retain resource discipline

**There is no fixed product limit on agent profiles, sessions, or runs.**
Execution still depends on available resources and provider constraints.
The developer sees those constraints instead of an unexplained limit of eight.

The registry uses stable identities and dynamic storage.
Numeric shortcuts address favorites, not array positions.
Startup restores historical metadata.
It launches processes only when required.

The scheduler separates defined work from active work.
It admits steps under the resource policy and preserves fairness between runs.
A queued step displays its reason.
Optional user budgets remain explicit controls rather than hidden product ceilings.

ACP sessions represent independent conversations.
Session restoration depends on advertised support. [5]

The execution layer therefore separates a connection from its sessions.
Adapters use shared processes only after conformance tests establish safe session independence.
Other adapters use separate processes.

Memory queues remain bounded.
Large histories move to persistent storage with a visible retention policy.
Backpressure must not starve cancellation or permission responses.
An exhausted storage budget produces an explicit state instead of silent data loss.

Usage displays distinguish reported values from estimates.
Absent cost information appears as `Unknown`, not `$0`.
ACP makes cumulative cost optional in its usage updates. [4]

### Concurrency needs change isolation

Independent write branches receive separate candidate workspaces by default.
A sequential pipeline can retain one candidate workspace across its steps.
An explicit join integrates branch outputs before final tests.

Git worktrees provide separate checkouts, but they share repository data. [6]
They are not a substitute for process isolation.
The execution policy distinguishes checkout isolation from filesystem and network restrictions.

ACP agents execute tools themselves and can optionally request client permissions. [7]
A policy label alone therefore cannot establish an operating-system restriction.
The UI displays `Read-only` only when an execution boundary enforces that restriction.
An unrestricted process receives an honest status label.

The apply service checks source revisions before it changes the developer’s workspace.
Its recovery journal covers interrupted multi-file application.
It preserves unsaved buffers and exposes conflicts.
A retry never blindly repeats an external side effect.

## 5. Keep the native core responsible for the guarantees

The renderer remains Zig plus SDL3 GPU.
The redesign does not require Electron or a browser surface.
The renderer wakes for input, invalidation, or intentional animation rather than continuous idle redraw.

The core owns execution identity and document transactions.
It also owns policy enforcement and durable run records.
Views observe these services.
They do not own agent processes.

TypeScript extensions can contribute workflow steps and native interface descriptions.
They use the same permission boundary as built-in features.
A separate JavaScript context is not the definition of an extension sandbox.
Extension failures need execution budgets and containment outside the UI event loop.

The execution engine must not depend on an open panel.
Panel closure never cancels a session by accident.
Crash recovery marks uncertain work as interrupted.
It never claims exactly-once completion.

The ACP adapter layer negotiates supported features.
Unsupported resume or model controls remain unavailable with an explanation.
Generic `Pause` never claims a protocol capability that the adapter lacks.
`Pause after this step` can remain a scheduler operation.

The checked ACP documentation still labels v2 as Draft. [8]
Seggs needs a versioned protocol boundary rather than a UI coupled to one wire schema.
A protocol upgrade does not block the first composition release.

## 6. The release roadmap

The next serious push covers R0 through R3.
R4 exposes that work through a reusable, programmable interface.
R5 establishes broader daily-driver confidence.

The releases use acceptance gates rather than unsupported calendar promises.
The UI track and execution track proceed together.
Each release needs a visible product improvement and an executable test fixture.

### R0 — Contract reset

The runtime gains stable identities and dynamic session storage.
The schema loses its eight-agent cap.
The command system uses the same identities as the composer and navigator.

A native component gallery establishes the new visual direction.
It includes focus behavior and accessible semantics.
The build contract resolves the recorded Zig 0.16.0/0.17.0 mismatch.
The original 0.16.0 requirement remains the default unless an explicit project decision changes it.

**Exit gate:** The ninth agent behaves like the first.
A 1,000-profile fixture restores without 1,000 process launches.
No late event routes into a different session after deletion or restart.

### R1 — The workbench feels like an editor

The shell gains the new dock system and typography.
The explorer gains a real tree and visible exclusions.
The composer gains explicit identity and inspectable context.

Multi-buffer tabs and splits support ordinary code work.
The run inspector replaces raw protocol text as the default agent view.
Saved layouts preserve focus and selection state.

**Exit gate:** A new user can identify the prompt destination from the composer alone.
A keyboard-only path covers file selection, context attachment, and prompt submission.
Scale changes do not produce clipped controls or misplaced pointer targets.

### R2 — One real cross-agent pipeline

The engine supports sequential agent, command, and human-gate steps.
Artifacts preserve source revisions across the pipeline.
A candidate workspace separates generated changes from the developer’s active tree.

The review perspective links code changes to command evidence.
An internal CLI exercises the same execution engine.
A local mock fixture covers the entire path without provider accounts.

**Exit gate:** Oh-My-Pi can plan a change that Codex implements and Claude Code reviews.
A test command evaluates the candidate before the developer accepts it.
The task requires no transcript copy-and-paste between harnesses.
A failed step cannot silently become a successful run.

### R3 — Parallel work remains understandable

The engine gains fork, join, and map steps.
Each independent write branch receives a separate candidate workspace.
The scheduler exposes resource pressure and queue reasons.

The decision inbox consolidates approvals.
Each decision retains its own scope.
The run navigator supports large histories through virtualization.
Cancellation has explicit effects on dependent and independent steps.

**Exit gate:** Three implementation candidates can start from one snapshot and receive the same tests.
A cancelled branch cannot apply its result later through a stale approval.
A 100-session mock workload leaves code input responsive.
These fixture sizes are test points, not product limits.

### R4 — Workflows become reusable tools

Versioned workflow files live under `.seggs/workflows/`.
The visual editor and text editor share one definition.
The public CLI supports ordinary shell pipes and structured artifacts.

The workflow inspector exposes capabilities before execution.
A missing harness produces a setup action, not an opaque runtime failure.
Imported workflows require trust before executable steps can start.

**Exit gate:** The same workflow runs through the UI and CLI with equivalent inputs and policy.
A harness change leaves the workflow’s dependency structure intact.
A new run can reuse a completed artifact.
Reuse does not invoke the source step again.
The UI distinguishes stored results from new execution.

### R5 — Daily-driver confidence

This release completes the editor baseline rather than attempts immediate VS Code parity.
The baseline includes workspace search, reliable save behavior, and incremental syntax support.
It also includes LSP completion and rename, plus a usable PTY terminal.

Native accessibility and text input remain active work from R0 onward.
This gate requires platform validation rather than a screenshot alone.
Release builds need reproducible tests for display changes and process cleanup.

**Exit gate:** A developer can complete a normal project task without another editor.
Crash recovery preserves documents and run records.
Supported platforms pass their declared native acceptance matrix.

## 7. The first development sprint

1. Replace slot-based agent identity throughout the schema and runtime.
2. Add durable run and artifact identifiers below the UI.
3. Build the native component gallery with the proposed typography and layout.
4. Replace the agent roster with a run navigator and an explicitly scoped composer.
5. Connect two mock agent steps through one immutable artifact.
6. Add a candidate diff and a human approval gate to that path.

### Sprint demonstration

The demonstration starts with selected code in the editor.
One mock produces a plan.
Another mock produces a candidate change.
The developer inspects its provenance and accepts it through Review.

This slice proves the new product model and the new interaction model together.
It avoids a month of invisible runtime work followed by a separate UI rewrite.

## 8. Measures that keep the overhaul honest

These are initial acceptance targets, not current measurements.
Performance results need named hardware and a reproducible workload.

| Area | Initial acceptance target |
| --- | --- |
| Destination clarity | At least four of five new test users identify the target without assistance. |
| Composition | One cross-harness task completes without transcript copy-and-paste. |
| Input response | The 95th-percentile local input-to-visible-update time stays below 50 ms under the mock workload. |
| Frame delivery | The 95th-percentile visible frame time stays below 16.7 ms on declared 60 Hz reference hardware. |
| Scale | The fixture covers 100 active mock sessions and 10,000 historical runs without per-token UI work across all runs. |
| Data integrity | Failure injection produces no lost user edits or cross-run approval leakage. |
| Recovery | A restart recovers history and explicitly identifies interrupted work. |
| Review quality | Every accepted change links to its source revision and available test evidence. |

The usability sample is a formative check, not a population estimate.
The scale fixture measures Seggs behavior, not provider concurrency guarantees.
The mock workload targets 20 updates per session per second and includes permission bursts.
The benchmark records payload sizes and transcript lengths.
Failure-injection success is a release gate, not proof that every possible failure is covered.

## Scope discipline

The first composition release does not need a marketplace or cloud control plane.
It does not need a new general-purpose scripting language.
A graph view does not take priority over correct artifact transfer and review.

Remote execution and shared team workflows follow the local execution contract.
A later ACP-facing adapter can expose an entire workflow as a single agent.
That adapter preserves scoped approvals and cancellation.
Advanced DAP features follow the daily-driver baseline.
A background execution service can later preserve active runs across UI shutdown.
That behavior remains distinct from local crash recovery.

**The milestone is not “Seggs can display more agents.”**
**It is “a developer can compose a team, inspect its work, and accept a tested change within one code workspace.”**

## Sources and baseline

The baseline comprises the user-provided screenshot and the older `seggs-scaffold.zip` archive.
External references establish protocol and platform boundaries.
They do not validate the proposed Seggs implementation.

1. Zed, Parallel Agents. https://zed.dev/docs/ai/parallel-agents
2. SDL, High-DPI support. https://wiki.libsdl.org/SDL3/README-highdpi
3. Agent Client Protocol, v1 Transports. https://agentclientprotocol.com/protocol/v1/transports
4. Agent Client Protocol, v1 Prompt Turn. https://agentclientprotocol.com/protocol/v1/prompt-turn
5. Agent Client Protocol, v1 Session Setup. https://agentclientprotocol.com/protocol/v1/session-setup
6. Git, git-worktree. https://git-scm.com/docs/git-worktree
7. Agent Client Protocol, v1 Tool Calls. https://agentclientprotocol.com/protocol/v1/tool-calls
8. Agent Client Protocol, ACP v2 is available in Draft. https://agentclientprotocol.com/announcements/acp-v2-draft

External documentation was checked on September 20, 2026.
