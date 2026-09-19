# Limitations

## Delivery validation

The delivery environment had no Zig compiler, SDL3 SDK, or shader compiler.
Network downloads for those native prerequisites failed.
Native compilation, shader compilation, and GPU execution remain unverified.
The included Linux CI workflow is a validation definition, not evidence of a completed run.

The Python fixture suite passed 11 tests.
That result validates the fixture's protocol behavior and subprocess scenarios.
It does not validate the Zig transport or the renderer.

## Editor

The app edits one UTF-8 document at a time.
The initial welcome buffer has no save-as operation.
A user must open an existing file before a normal save.
The app refuses a file switch when the active document has unsaved changes.

The atlas covers printable ASCII only.
Non-ASCII characters remain intact in the buffer, but the renderer displays a fallback glyph.
The app has no grapheme segmentation, shaping, bidirectional layout, font fallback, or IME composition interface.
It preserves existing line-ending bytes but inserts LF for new lines.

The scaffold has no multi-cursor edit model or multi-buffer tabs.
It has no full search/replace interface.
The lexical colors do not replace a language parser.
The fixed atlas scale does not adapt to every display density.

## Save path

The save path checks the loaded baseline before replacement.
It does not hold a cross-process lock across that check and the rename.
An agent can change the file during that interval.
The app does not provide a transactional shared-worktree edit protocol.

The temporary file receives the process's normal creation permissions.
The implementation does not preserve the original mode, ACLs, extended attributes, or hard-link relationships.
A symbolic-link path can become a regular file after replacement.
The implementation flushes the C stream but does not fsync the file and parent directory.
It does not claim power-loss durability.

The Windows path uses C `fopen` for the temporary file.
Unicode filenames need native validation and a platform-specific replacement path.
These limits make disposable worktrees the intended development environment.

## Workspace and performance

The explorer scans once and has no live watcher.
Its file count and depth are bounded.
The editor limits files to 8 MiB.
It copies the document after each revision and scans lines for layout.
It is not a large-file engine.

The UI redraws under vertical synchronization.
It has no idle-frame suppression or damage tracking.
The transcript wraps again each frame.
The prompt supports append, backspace, and paste, not a complete cursor model.

## ACP coverage

The scaffold implements a capability-limited ACP v1 stdio client.
It does not guarantee compatibility with every ACP agent or extension.
It supports one active session per configured process and one prompt per session.
A broadcast skips non-ready lanes.

Missing ACP features include:

- Client-driven authentication and session resume.
- Editor-backed filesystem and terminal services.
- Image, audio, and embedded resource prompts.
- Mode, model, and session configuration interfaces.
- Structured diff review and tool-specific rich renderers.
- Remote transports and extension-specific RPC methods.

Permissions apply only to requests that a harness exposes through ACP.
A harness can still use its own filesystem and terminal tools.
The advertised capability flags are not a sandbox.
A process stop does not guarantee cleanup of every descendant process.

## Platform and IDE scope

The shader sources cover Vulkan and Metal.
The project does not include D3D12 shaders or a fallback software renderer.
Linux is the first CI target.
macOS and Windows code paths remain experimental.

The scaffold has no LSP, DAP, PTY terminal, Git interface, extension host, or settings persistence.
The service contract file marks future interfaces explicitly.
The interface does not imply VS Code extension compatibility.
