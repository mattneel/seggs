# Roadmap

## Milestone 1: Native acceptance

The first release gate is a clean Zig 0.16 build on the target platforms.
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
