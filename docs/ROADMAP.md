# Roadmap

## Status

Four milestones, and most of what they named has landed. Each item below is
marked **landed**, with the gate that exercises it, or **open**, with what would
close it. A capability counts as landed only when a check can fail on it;
`docs/VALIDATION.md` names the test or check behind each one.

| Milestone | Where it is verified |
| --- | --- |
| Native acceptance | `core`, `native-linux`, `macos`, and `windows` jobs in `.github/workflows/ci.yml`; the screenshot gate runs on Linux and macOS with the Khronos validation layer enabled |
| Editor foundation | `zig build test` and the screenshot gate's text, baseline, composition, and fallback checks |
| Agent workspace | `zig build integration` against the mock, plus the live Oh-My-Pi and Claude Code turns, and the screenshot gate's run and compose checks |
| IDE services | `zig build test-native`, `zig build integration`, and the mock LSP and DAP fixtures |

Two landed items are covered by the nearest check rather than one named for
them: the save gate's conflict races are the watcher's external-edit detection
plus the review queue's conflict outcome, and a process flood is bounded by the
agent count limit and the transport's queue limits rather than by a flood test.

## Milestone 1: Native acceptance

**Landed:** a clean Zig 0.17 build on all three target platforms; resize,
minimize, fullscreen, and high-density transitions in the GPU gate; the ACP gate
against native pipes and against the real Oh-My-Pi and Claude Code adapters; the
save gate for permissions, symlinks, and external changes, with the
temporary-file replacement tests; and failure injection for allocations and for
the temporary-file path.

**Open:** hardware GPU validation (the gate's Vulkan runs use the software
lavapipe driver, and its macOS run reaches Vulkan through MoltenVK on Metal), a
Metal display test, and a Windows display run - a hosted Windows runner has no
Vulkan driver, so the workflow compiles the shaders there instead of presenting
frames.

## Milestone 2: Editor foundation

**Landed:** multiple documents with one active buffer, an incremental line
index, grapheme-aware movement, shaping through zignal with a fallback chain for
scripts the primary face lacks, inline IME composition, a lexical scanner that
carries block-comment state across lines, display mathematics typeset through
MicroTex, falling back to the source when the engine cannot lay a formula out,
and frame capture written in the format the path asks for - png, bmp, gif, jpg,
or ppm.

**Open:** a parse tree, because colouring is lexical and a theme rule for a scope
the scanner never produces is silently unused; a real workspace watcher, since
external edits are found by an mtime/size poll; and shaped advances, since lines
still use the metrics SDL_ttf rasterizes with so text keeps its columns.

## Milestone 3: Agent workspace

**Landed:** authentication when a preset names a method, session configuration,
a capability broker for editor-backed files and client-owned terminals, a review
queue that applies a proposed edit only at the revision it was proposed for, a
worktree manager that creates linked worktrees and reports conflicts, prompts
that carry the selection and the active file's diagnostics, and a run engine that
carries a workflow of agent, command, and approval steps and keeps every artifact
each produced, with a Compose perspective that reads the sequence left to
right.

**Open:** routing agent edits into the review queue (the surface exists, and
nothing in the ACP path proposes to it yet), worktrees wired into startup,
attaching files to a prompt, transcript persistence (the config flag and the
export both exist, and no interface control calls either), and a request that can
name more than one destination.

## Milestone 4: IDE services

**Landed:** a language server for diagnostics and code navigation, a debug
adapter for breakpoints and stopped sessions, a PTY for terminals with explicit
process ownership, and a Git service for worktree status and change diff.

**Open:** wiring the worktree and Git services into the interface, and the
language-service and debug-service interfaces declared in
`src/services/contracts.zig`, which have no implementations.
