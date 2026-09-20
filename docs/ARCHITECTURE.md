# Architecture

## Ownership

One application thread owns all editor and UI state.
Each ACP transport owns one worker thread and one process.
Only byte buffers cross the thread boundary.
Each queue has an SDL mutex and explicit ownership transfer.

```text
SDL events -> App -> Document / Workspace -> draw commands
                    |                         |
                    |                         v
                    |                   SDL3 GPU renderer
                    |                   vertex upload + atlas
                    |
                    +-> Client[0] <-> Transport[0] <-> harness[0]
                    +-> Client[1] <-> Transport[1] <-> harness[1]
                    +-> Client[N] <-> Transport[N] <-> harness[N]
```

`std.process.Init` supplies the Zig 0.17 allocator and I/O context.
The default general-purpose allocator supports concurrent use.
SDL handles processes and window events, which keeps obsolete Zig process APIs out of the app.
The [Zig reference](SOURCES.md) describes this entry point.

## GPU path

The renderer batches rectangles and glyphs into one vertex stream.
Each vertex contains position, texture coordinates, and color.
The glyph atlas also contains a white texel for solid rectangles.
A frame uploads the stream through a transfer buffer and submits one graphics pass.

Linux and Windows use SPIR-V from the GLSL sources.
The fragment sampler occupies set 2, binding 0, as SDL's Vulkan shader contract requires.
macOS uses the corresponding Metal source.
SDL owns the swapchain and the native graphics backend.

The renderer clips geometry and texture coordinates on the CPU.
It uses logical window coordinates, which map to the swapchain through normalized coordinates.
The atlas uses a fixed 2x raster scale.
It is not a complete display-scale or font-shaping system.

The loop uses vertical synchronization and redraws each frame.
It does not yet use damage regions or event-driven idle rendering.
A minimized window can return no swapchain texture, which the renderer handles separately.

## Document model

The document owns a gap buffer and an undo history.
All stored positions use byte offsets.
Edits validate UTF-8 and reject embedded NUL bytes.
Cursor movement is grapheme-aware per UAX #29 (flags, Hangul, CRLF, combining
marks), so arrows and backspace do not split grapheme clusters. Emoji ZWJ
sequences (rule GB11) are the one unhandled case.

A replacement allocates its history entries before it changes the buffer.
Undo records preserve removed and inserted text.
The history retains at most 128 entries and targets a 16 MiB payload cap.
A document accepts at most 8 MiB.

The document also maintains an incremental line-start index, rebuilt
atomically with each edit, undo, and redo.
Line navigation, cursor location, and click-to-position use it in O(log lines).
The renderer still splits the cached snapshot each frame to draw glyphs.
This design favors readable scaffold code over large-file performance.
The lexical scanner classifies tokens per language, detected from the file
extension, and carries block-comment state across lines; it has no parse tree.

## Workspace model

One workspace owns multiple open documents (buffers) with one active.
Opening a file switches to an already-open buffer or appends a new one.
Each buffer keeps its own document, on-disk path, and save baseline.
The explorer scans once at startup and skips common dependency and cache directories.
Its limits are 1,024 entries and three nested directory levels beyond the root.
Quick open performs a case-insensitive substring filter over those entries.

The save path compares disk bytes against the last loaded or saved baseline.
A conflict refuses the save.
A successful save resolves symlinks, then writes a temporary sibling and renames it over the destination, so saving through a link updates the file the link names.
A time-of-check race and metadata loss remain possible.

Each buffer records an mtime/size stamp. A one-second poll detects external
edits, and the active file can be reloaded (refusing while it has unsaved changes).

An agent does not receive the unsaved document automatically.
The client sends only the user's explicit prompt text and the session's working
directory, plus whatever the user attaches.
Editor-backed file reads and writes go through the capability broker, and a
prompt can carry the selection and the diagnostics the language server reported.

## ACP session state

```text
OFFLINE -> INITIALIZE -> NEW_SESSION -> READY -> BUSY -> READY
                                           |       |
                                           |       +-> CANCELLING -> READY
                                           |
                                           +-> stop -> OFFLINE

Any transport or handshake failure -> FAILED
FAILED -> explicit start -> INITIALIZE
```

Each lane owns its request counter and session identifier.
Only one prompt runs per lane at a time.
Different lanes run independently.
A broadcast reaches only the lanes that are ready at submission time.
Busy lanes do not receive a deferred copy.

The transport exchanges JSON-RPC objects, each followed by a newline.
The decoder accepts fragmented reads and several frames in one read.
It does not use LSP Content-Length headers.
Stderr remains inherited and never enters the JSON decoder.

The UI pumps at most 64 packets per lane per frame.
Each queue accepts at most 128 packets and 8 MiB.
A frame accepts at most 1 MiB.
A transcript retains at most 512 KiB with UTF-8 boundary-aware trimming.

Initialization has a 30-second deadline.
Session creation has a 60-second deadline.
Cancellation has a 10-second deadline.
Ordinary prompts have no arbitrary completion deadline.

## Capability and permission boundary

The client advertises the filesystem capability (read and write text files)
and the terminal capability, and handles `fs/read_text_file`,
`fs/write_text_file`, and the `terminal/*` request family.
The terminal broker owns each process: the agent receives only a terminal id,
output is bounded, and `terminal/release` or client shutdown reaps the process.
`terminal/wait_for_exit` waits on a bounded deadline so a command that never
exits cannot stall the app thread.
It also parses the `configOptions` the agent returns on `session/new` and can
set them via `session/set_config_option`.
Unknown client requests receive JSON-RPC error `-32601`.
Unknown optional notifications do not affect the session.
This baseline supports agents that accept those capability choices.

The client retains one permission request per lane.
Additional simultaneous permission requests receive a cancelled outcome.
Approval selects only an `allow_once` option.
A request with no one-time option does not become an always-allow grant.

The interface shows the tool title and preserves the structured tool details in the transcript.
Alt+Y and Alt+N prevent ordinary prompt characters from acting as approval shortcuts.
A permission remains local to its request and session.

## Extension contracts

`src/services/contracts.zig` defines language-service and debug-service interfaces;
those async interfaces have no implementations. A minimal synchronous LSP client
(`src/services/lsp.zig`) speaks Content-Length framing to a language server,
collects diagnostics, and resolves definitions, references, and hover. It is
driven from the app: opening a file restarts the server, diagnostic lines get a
gutter mark, F12 jumps to a definition, Shift+F12 reports references, and Ctrl+I
shows hover. A minimal DAP client (`src/services/dap.zig`) uses the same
framing to launch a debug session, observe the stopped event, read the stack
trace and variables, and resume with continue or step. A PTY service
(`src/services/pty.zig`) forks a shell onto a pseudo-terminal (POSIX only).
A prompt carries the editor context the agent needs: `src/editor/prompt.zig`
attaches the active selection and the language server's diagnostics for the
active file, each labelled with its file and one-based line.
`ProposedEdit` carries an expected document revision. A review queue
(`src/editor/review.zig`) applies it only when the document revision still
matches, so a stale edit is reported as a conflict rather than applied.
The ACP client does not yet route agent edits through the queue.

A worktree service (`src/services/worktree.zig`) runs `git` synchronously
through SDL_Process to create linked worktrees and detect unmerged files.
A Git service (`src/services/git.zig`) returns worktree status and change diff.
The app does not yet wire either into the startup flow.

## Font and text

`src/gpu/shaper.zig` owns glyph selection: it parses the font through zignal's
TrueType reader and answers "which glyph index, and how far does the pen move".
`src/gpu/atlas.zig` then rasterizes that glyph index from the system font on
first use and packs it into one texture, so the two concerns stay separate and
coverage follows the font rather than a fixed codepoint table. The atlas is a
cache: when it fills, a glyph reuses the placeholder and the host counts the
miss. No font binary is bundled or redistributed.

Packing lives in `src/gpu/packer.zig`, which is pure logic and directly tested.
Newly rasterized glyphs queue a dirty rectangle that `Atlas.flush` uploads before
the frame is drawn.

Cursor movement is grapheme-aware through the UAX #29 tables in
`src/core/grapheme_data.zig`, so a combining sequence or an emoji moves as one
unit rather than one byte at a time.

`src/core/preedit.zig` holds the in-progress IME composition. Committed text
arrives as a separate text-input event, so the composition never duplicates it.
The composition is drawn inline at the cursor with an underline and ends when an
update arrives with empty text.

When the primary face has no glyph, the codepoint is resolved through a
fallback chain registered with SDL_ttf, so scripts the monospace face does not
cover — CJK, for instance — still draw. Fallback glyphs are cached by codepoint
rather than by index, because glyph indices are only meaningful within one font.
A codepoint no registered face can draw keeps the placeholder.

Glyph selection and codepoint mapping come from the shaper. Horizontal advances
still use the metrics SDL_ttf rasterizes with, so lines keep the hinted spacing
they had before shaping was introduced; a shaped advance differs by a fraction
of a pixel per glyph, and using it shifts every line. Editor column arithmetic
still assumes a uniform monospace advance. Ligature substitution and
complex-script joining are not implemented, and a fallback face is used as-is:
its own metrics decide advances, so a proportional fallback does not align to
the editor's column grid.

## Extension host

`src/ext/host.zig` embeds QuickJS-NG through the `quickjs_ng` dependency. Every
bundle gets a runtime and a context of its own: a bundle can then be unloaded and
reloaded without disturbing the others, everything it registered goes away with
it, and two extensions cannot collide in a shared global scope.

A bundle is built from `extensions/src` by `extensions/build.mjs` into a single
IIFE script in `extensions/dist`. esbuild is a development dependency only; the
shipped binary never invokes it, and a bundle written by hand is the same
language.

Four ownership rules matter for this host:

- Callbacks reach the host and the extension they belong to through thread-local
  pointers set before each call, because `Host` is returned by value and storing
  `&self` in a context would dangle.
- `setPropertyStr` takes ownership of the value it stores. The `seggs` object
  belongs to the global object once installed and must not be released again.
- A snapshot is kept as text rather than as a JavaScript value, because a value
  belongs to the context that created it and there is more than one context now.
- The app owns the ids it collects from a panel, because the tree those ids point
  into is parsed per panel and freed as soon as the next one is read.

A bundle that throws stays in the list with its message, which is what an author
or an agent reads to fix it, and reloading is triggered by the bundles changing
on disk. A missing `extensions/dist` directory is not an error, so the app runs
without a JavaScript toolchain installed.

The host is single-threaded and follows the application thread. Editor and JSON
state stay on that thread; extensions never run on a transport worker. A panel is
asked for its description during the frame it is drawn in, so a bundle that never
yields holds up that frame; a context per extension bounds the damage to that
extension's own requests rather than the editor.
