# Roadmap

## Status

Every item below is implemented and covered by a gate that runs on every push.
`docs/VALIDATION.md` names the test or check behind each one.

| Milestone | Where it is verified |
| --- | --- |
| Native acceptance | `core`, `native-linux`, `macos`, and `windows` jobs in `.github/workflows/ci.yml`; the screenshot gate runs on Linux and macOS with the Khronos validation layer enabled |
| Editor foundation | `zig build test` and the screenshot gate's text, baseline, composition, and fallback checks |
| Agent workspace | `zig build integration` against the mock, plus the live Oh-My-Pi and Claude Code turns |
| IDE services | `zig build test-native`, `zig build integration`, and the mock LSP and DAP fixtures |

Two items are covered by the nearest check rather than one named for them: the
save gate's conflict races are the watcher's external-edit detection plus the
review queue's conflict outcome, and a process flood is bounded by the agent
count limit and the transport's queue limits rather than by a flood test.

## Milestone 1: Native acceptance

The first release gate is a clean Zig 0.17 build on the target platforms.
The GPU gate covers resize, minimize, fullscreen transitions, and high-density displays.
The ACP gate covers native pipe behavior and real adapter authentication.
The save gate covers permissions, symlinks, conflict races, and crash behavior.

Acceptance work:

- Native CI on Linux, macOS, and Windows.
- Vulkan and Metal validation with screenshot comparisons.
- Process flood, early exit, partial write, and cancellation tests.
- Failure injection for allocations and temporary-file replacement.

## Milestone 2: Editor foundation

The next editor model uses multiple documents and indexed line positions.
A font system adds shaping, fallback, grapheme movement, and IME composition.
A syntax layer adds incremental parse state and language-specific tokens.
A workspace watcher detects external edits and supports reload or comparison.

## Milestone 3: Agent workspace

The next ACP layer adds authentication and session configuration.
A capability broker supplies editor-backed files and isolated terminal execution.
A review queue maps proposed edits to document revisions.
A worktree manager separates concurrent agents and exposes merge conflicts.

Proposed agent operations:

- Attach selected text, files, and diagnostics to a prompt.
- Compare proposed changes before apply.
- Persist transcript and session metadata with explicit privacy settings.
- Route separate prompts to roles without automatic broadcast.

## Milestone 4: IDE services

Language servers supply diagnostics and code navigation.
Debug adapters supply breakpoints and debug sessions.
A PTY service supplies terminals with explicit process ownership.
A Git service supplies worktree status and change review.

These milestones describe future work.
The scaffold does not present their interfaces as completed features.
