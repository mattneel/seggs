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

## Shell and layout

`src/ui/layout.zig` computes the frame from the cell metrics rather than from a
fixed set of pixels: the activity rail, the left dock, the editor, the terminal,
the agent dock, and the status bar are placed afresh each frame, so a font or
density change moves the chrome with the text instead of around it.

There is no title bar. The window opens on the background colour and a one-line
wordmark, because the space a bar takes is worth more than the name of the
program that is already on screen.

Every dock resizes by dragging the divider between it and its neighbour. The hit
test is a four-pixel band on the boundary, since a one-pixel divider is one
nobody can hit, and the drag does no more than record what the reader asked for:
the layout decides what that means, which is why a drag past a limit lands on the
limit without the drag handler knowing any of the limits.

Those limits exist because two docks dragged independently would take the window
between them. The left dock is clamped against the width the agent dock wants
plus the editor's own minimum, and the agent dock against what the left dock has
already taken, so the editor keeps at least 200 device pixels of width however
the drags went. The terminal keeps at most half the height of the body, and a few
rows is the least it can be read in. Clamping in the layout rather than in the
handler is also what keeps a window resize and a dragged divider from
disagreeing about what the docks may have.

Below 1040 device pixels the file list is dropped, and below 880 the agent dock with
it, so a narrow window spends its room on the file rather than on the chrome
around it.

## Lists and overlays

Quick open, the command palette, the agent templates, the destinations a request
can be sent to, and the shells this machine offers are one widget
(`src/ui/menu.zig`) with one set of keys: they differ in what they name, not in
how they behave. The widget has two placements, and the difference is where the
list came from. A list opened by a control hangs under that control and is at
least as wide as it; a list opened by a key is centred over the window, because
there is no control to hang from. `Ctrl+Shift+A` opens the agent templates,
`Ctrl+Shift+Enter` the destinations, and the `+` at the end of the agent strip
opens the same template list placed under itself.

The rows are gathered when a list opens. Nothing that fills them can change
while it is up - every other key belongs to the list - so rebuilding them per
frame would be work with no reader behind it.

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

## Themes

A theme is a document, and `src/ui/theme.zig` is the format: JSON holding the
chrome roles, a terminal palette, and syntax rules written as TextMate scope
selectors. A key that is absent keeps the default, so a document may be two
colours or a full theme; colours are `#rgb`, `#rrggbb`, or `#rrggbbaa`.

The chrome roles are module-level variables that draw sites already read by name
- `theme.text`, `theme.panel` - and `apply` is their only writer. That is what
makes theming reach every draw call without touching one: loading a theme is one
list of assignments, and no site had to be written with theming in mind to be
repainted by it. The roles are the twelve names an editor theme also uses plus
the two diff roles, `added` and `removed`, which no editor theme names and the
transcript needs. `current` carries the same theme as a document, and the syntax
side resolves a scope name against it.

`--theme <path>` loads one, and the format is decided by the document rather than
by the file's name, because a theme that has been renamed is still a theme: an
XML plist is a TextMate `.tmTheme`, a JSON document that names token colours is a
VS Code colour theme, and anything else is the native format. Both importers
exist because those are the themes people already have; neither is complete, and
[limitations](LIMITATIONS.md) names what each drops. Loading is not fatal - a
theme that fails to parse leaves the last good one in place and says why - and
`themes/monokai.json` is the shipped example.

Syntax colouring reaches a theme through named roles rather than through literal
scopes: `src/editor/highlight.zig` classifies a token and answers with
`comment`, `string.quoted`, `keyword.control`, `constant.numeric`, or
`storage.type.annotation`, and those names are what a rule's selector matches. A
rule for a scope the scanner never produces is silently unused, which is the cost
of classifying lexically instead of parsing.

The terminal half of the format exists because a shell is drawn by the emulator
and not by the editor's own draw calls: the only way the editor's colours reach
it is by being pushed across. The push is skipped when no theme was loaded,
because the placeholder default - sixteen ANSI entries that are all the
background colour - is fine as a document's default and wrong as something to
hand to a running program.

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
A request names one lane, chosen at the composer or out of the destination list;
a lane that is not ready refuses it rather than holding it for later, and the
editor says which lane refused.

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

## Agent dock and liveness

The dock's tabs are the lanes that are running, not a menu of the ones that
could run: a lane nobody started is something the template list offers, not a tab
the reader is paying for, and the dock is gone entirely when nothing is up - the
same rule as the terminal, which has no dock without a shell in it. Opening a
tab is what starts an agent, so there is no separate start step in the interface,
and closing one stops the lane and moves the dock to whatever is still running.

The ACP layer knows what arrived and deliberately knows nothing about when. The
client keeps counters - the transcript's length, the number of tool events, the
number of updates it has processed, and its own state - and never reads a clock;
the App samples those counters once a frame instead, and the timing lives there.
A turn is in flight exactly while the lane reports one of its working states, so
the two edges of a turn are the state's edges: the App does not need anyone to
tell it that a prompt went out or came back, which matters because a prompt
leaves the editor from two places (the composer and a run step) and the state is
the one thing both have in common. A transcript that has filled up and started
dropping its front is why the update counter, and not the transcript length, is
what the silence is measured against: its length alone would read a working turn
as gone quiet.

What the reader sees is derived from that record: how long the turn has run, how
long it has been silent, and, past twenty seconds of silence, the word `stalled`
with the duration, in the line under the tab strip. The tab itself has room for a
dot and not a line, so it shows the phase's colour alone - red for a stalled or
failed lane, which is the only place a reader can see trouble in a tab they are
not looking at. The line is produced by a pure function in `src/ui/activity.zig`
that writes into a buffer its caller owns and reads no clock, so the same facts
draw the same words on any machine and the drawing allocates nothing per frame.

## Transcript

An agent's prose is Markdown, and the panel renders it: headings, bullets,
quotes, rules, fenced code, and inline runs. A fenced block that reads as a
unified diff is drawn as one, in the theme's added and removed colours; any other
fence goes through the editor's own tokenizer with the language the fence names,
so a transcript and the file beside it colour code the same way. A document the
parser refuses - it is bounded in both bytes and blocks, because the text comes
from a process the editor does not control - is wrapped and drawn plainly and
reported once, since a transcript that cannot be styled is still a transcript.

Tool calls are records rather than text. `src/acp/tool_call.zig` parses an update
into a call with a kind, a state, a one-line subject, labelled fields, an
optional diff, and the field the drawing depends on: the byte offset in the
transcript where the call arrived. The transcript bytes stay exactly what the
agent said, and the panel walks the calls in order, drawing the prose up to each
offset and then the call, so a chip lands where it happened rather than at the
end of the lane's text. A later update merges into its record and keeps the first
offset, which is what stops a chip sliding down the transcript as the call
progresses, and dropping the front of a transcript moves every offset with it.
Nothing JSON-shaped reaches the interface: a field is a path, not a key and its
escaped value. A chip opens on a click; the reader's answer is kept against the
lane and the agent's own id for the call, because the record itself is replaced
as the call progresses and two lanes can name a call the same thing. A call that
cannot be parsed at all still leaves its title as a line of text, since a call
that happened should not vanish because its shape was wrong.

Exporting a lane writes the prose and then a `[Calls]` trailer: one line per
call, its kind in brackets, its state, and its subject, in arrival order.

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
matches, so a stale edit is reported as a conflict rather than applied. The
review surface in the centre of the window lists what is waiting with the file,
the byte range, and the first line of the replacement, and says which change is
ready to apply and which is blocked; accepting or rejecting one is a key while
that surface is in front. The ACP client does not yet route agent edits through
the queue, so what is waiting got there from a test, a gate, or the person.

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

## Terminal

`src/services/vt.zig` owns one terminal: libghostty-vt's emulator state, the
render state a surface draws from, and the encoders that turn input into the
bytes a program expects. The library parses escape sequences, keeps the screen,
scrollback, and modes, reflows on resize, and encodes keys, mouse reports,
focus events, and pastes; the editor supplies the window, the renderer, and the
decisions about what it draws.

The dock holds tabs, not one shell. `src/services/terminals.zig` owns a session
per tab - a shell, the emulator that reads it, and the title the tab shows -
because a shell's state belongs to that shell, and two tabs sharing one screen
would be two views of one conversation. A tab runs the reader's own shell, or one
the machine offers: `Ctrl+Shift+T` reads `/etc/shells` and validates each entry,
because the system's own answer to which shells are installed beats a guess, and
drops an entry that cannot actually start - a row that cannot start is worse than
a shorter list. The list is read once and kept, since the installed set does not
change while the editor runs. `src/services/shell.zig` does the same for a
shell's output: bash and zsh are handed a snippet that makes them emit OSC 133
command markers, so a command's boundaries come from the shell rather than from a
guess about where a prompt ended, and a shell the integration does not know is
run exactly as it always was.

The shell is told the terminal's size when it is born and again whenever the dock
changes. The size travels with the pty at spawn, and a later change goes out as a
window-size ioctl, which the kernel delivers to the program as SIGWINCH - a
program that starts life on a zero-width screen lays its first prompt out to
nothing and stays that way, which is why the size cannot wait until after the
shell has spoken. A program's own title (OSC 0/2) becomes the tab's label, read
once per write to the emulator rather than once per frame, because a title can
only change when bytes arrive. `exit` closes the tab, and the last tab takes the
dock with it, because a dock with nothing in it is a dock taking up room.

The keyboard is split rather than shared. Typed text and the keys a terminal
actually sends - arrows, Home and End, Page Up and Page Down, Delete, Escape, the
function keys - are encoded by the library from the terminal's own modes and
written to the shell, so application cursor mode and the Kitty protocol mean what
the program asked them to mean. The editor's own shortcut table is consulted
first, so the Ctrl keys remain the editor's; the ones that make sense in a
terminal are the dock's own: `Ctrl+` opens or hides it and `Ctrl+Shift+T` opens
another tab. Selection, copy, and paste belong to the editor: the emulator
reports the cell a point is on and the editor draws the run between two of them,
copy is `Ctrl+Shift+C`, and a paste goes through the emulator's encoder so the
program sees what it asked for - bracketed wrapping when it enabled it, and
control bytes stripped.

The split is the same one Ghostling makes with Raylib and Ghostty makes with
Metal, and it is why nothing in the library knows about Seggs: the render state
is rows of cells with graphemes and styles, and the editor walks them into
batched quads and glyphs like it does for its own text. The dock's geometry
comes from `src/ui/layout.zig`, which splits the editor's column rather than
the window, so the explorer and the agent column keep their heights.

The library is C, so it crosses `translate-c` like SDL and Yoga. It is built by
the Zig release Ghostty's manifest names rather than this repository's, and the
C ABI is the boundary between them; `tools/bootstrap_ghostty.py` does that
build and `-Dghostty-prefix` says where it landed. A surface holds buffers for
one row's cells, because the render call fills a buffer per cell and the
slices must not borrow one that the next cell overwrites.

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
