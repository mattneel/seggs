# Limitations

## Delivery validation

The native build and the runnable acceptance gates now pass on Linux.
The Zig 0.17.0 toolchain is present, and the dependency bootstrap built SDL 3.4.4 and SDL_ttf 3.2.2.
Native compilation, core tests, the ACP transport test, and shader compilation are verified.
The renderer renders and presents frames under software Vulkan (lavapipe) and Xvfb.
Hardware Vulkan, Metal, macOS, and Windows remain unverified.
The included Linux CI workflow is a validation definition, not evidence of a completed run.

The Python fixture suite passed 11 tests.
That result validates the fixture's protocol behavior and subprocess scenarios.
The native integration test now also exercises the Zig transport.
The renderer path is verified with a software Vulkan driver; hardware GPU presentation is not.

## Editor

The app edits one UTF-8 document at a time.
The initial welcome buffer has no save-as operation.
A user must open an existing file before a normal save.
The app refuses a file switch when the active document has unsaved changes.

The atlas rasterizes printable ASCII up front and any other codepoint on first use, through the primary face and then the registered fallback chain. A script no available face covers draws the placeholder glyph and is counted.
Grapheme segmentation follows UAX #29 except rule GB11 (emoji ZWJ sequences), which needs the separate Extended_Pictographic property.
Glyph selection runs through zignal's OpenType tables, and the atlas supplies the advances, so advances come from the same hinted metrics as the rasterized bitmaps rather than from shaped positions. Kerning and contextual substitution are therefore unused, which a monospace grid makes moot: every advance in the primary face is the same, and text stays on the grid. Complex scripts that need joining forms or reordering, such as Arabic or Indic, still draw each codepoint in isolation.
Composition text arrives through SDL's text editing events and is drawn at the cursor with the reported selection highlighted and an underline, until committed text replaces it.
Bidirectional layout is not implemented.
It preserves existing line-ending bytes but inserts LF for new lines.

The scaffold has no multi-cursor edit model.
It has no full search/replace interface.
The lexical colors do not replace a language parser.
The fixed atlas scale does not adapt to every display density.
The atlas uploads its whole texture when a glyph is added, because a partial copy of an optimally tiled image is only permitted to the extent the queue family's image transfer granularity allows, and the D3D12-based Dozen driver reports no granularity and then rejects the copy. Uploads happen when a glyph is added rather than per frame, so the cost is bounded by the number of new glyphs.

## Save path

The save path checks the loaded baseline before replacement.
It does not hold a cross-process lock across that check and the rename.
An agent can change the file during that interval.
The app does not provide a transactional shared-worktree edit protocol.

The temporary file receives the process's normal creation permissions.
A save resolves symlinks first, so it replaces the file the link names rather than the link; this uses POSIX `realpath`, and the Windows path keeps the literal name.
A target file that is itself read-only is replaced, because the temporary sibling and the rename are governed by the containing directory; this follows the usual rename semantics.
The implementation does not preserve the original mode, ACLs, extended attributes, or hard-link relationships.
A symbolic-link path can become a regular file after replacement.
The implementation flushes the C stream but does not fsync the file and parent directory.
It does not claim power-loss durability.

The Windows path uses C `fopen` for the temporary file.
Unicode filenames need native validation and a platform-specific replacement path.
These limits make disposable worktrees the intended development environment.

## Workspace and performance

The explorer scans once and does not watch for new or deleted files.
The active file's external edits are detected by an mtime/size poll and can be reloaded.
Its file count and depth are bounded.
The editor limits files to 8 MiB.
It copies the document after each revision.
Line positions are indexed for O(log lines) navigation and status lookup;
the renderer still splits the cached snapshot each frame to draw glyphs.
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
- Editor-backed terminal services.
- Image, audio, and embedded resource prompts.
- A config-option selector UI (the client parses and sets `configOptions` but does not render a selector).
- Structured diff review and tool-specific rich renderers.
- Remote transports and extension-specific RPC methods.

Permissions apply only to requests that a harness exposes through ACP.
A harness can still use its own filesystem and terminal tools.
The advertised capability flags are not a sandbox.
The terminal broker runs commands the agent asks for with the client's own
privileges; it isolates ownership and output, not authority.
`terminal/wait_for_exit` blocks the app thread for up to five seconds.
A process stop does not guarantee cleanup of every descendant process.

## Terminal

The emulator is libghostty-vt, so its parsing, modes, and encodings are as
complete as the library's. What the editor draws from it is narrower: bold and
italic are parsed and not shown, because the atlas is rasterized from one face
and has no second weight or slope to draw them with; inverse and underline are
drawn. A grapheme's first codepoint is drawn and its combining marks are not,
because the atlas maps codepoints rather than shaped runs.

Kitty graphics is parsed by the library and not drawn: the renderer would need
image decoding and a texture path it does not have. There is no scrollbar, so a
viewport scrolled into history shows no indication of where it is until it is
scrolled back. Page Up and Page Down go to the program rather than to
scrollback, which is what applications expect.

The terminal needs a PTY, so it exists where `forkpty` does: Windows has no
terminal dock, and `services/pty.zig` names a type there that refuses rather
than a declaration the linker would have to find. The dock starts the user's
shell from `SHELL`, or `/bin/sh`, and the editor has no setting for choosing
another one yet.

## Platform and IDE scope

The shader sources cover Vulkan and Metal.
The project does not include D3D12 shaders or a fallback software renderer.
Linux is the first CI target.
macOS and Windows code paths remain experimental.
The font atlas rasterizes glyphs on demand from one system font, so coverage follows that font rather than a fixed table, and cursor movement is grapheme-aware with inline IME composition. Glyph selection is shaped through zignal, but advances still come from the rasterizer's hinted metrics, so shaped advances are unused. A fallback chain covers scripts the primary face lacks, but a proportional fallback does not align to the editor's column grid, and ligature or complex-script substitution is not implemented.
The screenshot gate compares two renders from the same build and driver; it is a
determinism and content check, not a comparison against a committed per-platform
reference image.

Prompts attach the selection plus diagnostics already collected for the active file; diagnostics from other open documents are not attached. SeggsC extensions describe interface, take events, and ask the editor to act, but they cannot read buffer contents, register commands in the palette, reach the IDE services, or persist settings. A PTY service (POSIX-only) forks a shell; a minimal LSP client collects diagnostics and resolves definitions, references, and hover; a minimal DAP client observes breakpoints, stack traces, and variables; and a Git service provides worktree status and change diff.
The service contract file marks future interfaces explicitly.
The interface does not imply VS Code extension compatibility.

## SeggsC

The language is a DSL rather than a general one: an extension can describe
interface, take events, and make requests, and nothing else. There is no way to
read the document, reach the renderer, or inspect another extension's state.

Extensions run in a JavaScript engine, so a bundle that loops without yielding
blocks the editor: panels are asked for a description during the frame they are
drawn in. A context per extension limits the damage to that extension's own
requests, and the reload report says which bundle failed, but there is no
preemption and no memory ceiling per extension.
