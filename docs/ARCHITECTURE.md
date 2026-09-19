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

`std.process.Init` supplies the Zig 0.16 allocator and I/O context.
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
Cursor movement respects Unicode scalar boundaries, not grapheme boundaries.

A replacement allocates its history entries before it changes the buffer.
Undo records preserve removed and inserted text.
The history retains at most 128 entries and targets a 16 MiB payload cap.
A document accepts at most 8 MiB.

The UI caches a full snapshot after a document revision changes.
The renderer draws visible lines, but line lookup still scans the snapshot.
This design favors readable scaffold code over large-file performance.
The lexical scanner is line-local and has no parse tree.

## Workspace model

One workspace owns one active document.
The explorer scans once at startup and skips common dependency and cache directories.
Its limits are 1,024 entries and three nested directory levels beyond the root.
Quick open performs a case-insensitive substring filter over those entries.

The save path compares disk bytes against the last loaded or saved baseline.
A conflict refuses the save.
A successful save writes a temporary sibling and renames it over the destination.
A time-of-check race and metadata loss remain possible.

An agent does not receive the unsaved document automatically.
The client sends only the user's explicit prompt text and the session's working directory.
Editor-backed file services and context attachments remain extension work.

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

The client advertises filesystem and terminal capabilities as false.
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

`src/services/contracts.zig` defines language-service and debug-service interfaces.
Those interfaces have no implementations.
`ProposedEdit` carries an expected document revision for a future review/apply pipeline.
The runtime does not yet route ACP edits through that contract.
