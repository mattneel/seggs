# Limitations

## Delivery validation

The native build and the runnable acceptance gates now pass on Linux.
The Zig 0.17.0 toolchain is present, and the dependency bootstrap built SDL 3.4.4 and SDL_ttf 3.2.2.
Native compilation, core tests, the ACP transport test, and shader compilation are verified.
The renderer renders and presents frames under software Vulkan (lavapipe) and Xvfb.
Hardware Vulkan, Metal, macOS, and Windows remain unverified.
The CI workflow covers Linux, macOS, and Windows as a validation definition; no
completed run of it is evidence in this document.

The Python fixture suite passed 11 tests.
That result validates the fixture's protocol behavior and subprocess scenarios.
The native integration test now also exercises the Zig transport.
The renderer path is verified with a software Vulkan driver; hardware GPU presentation is not.

## Editor

The app edits one UTF-8 document at a time, with several open: each buffer keeps
its own document and save baseline, so switching away and back does not lose
unsaved work.
The initial welcome buffer has no save-as operation, so a user must open an
existing file before a normal save.
Reloading from disk is refused while the buffer has unsaved changes, and so is
closing it.

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

## Transcript and liveness

The transcript reads Markdown, not a Markdown implementation: headings,
bullets (an ordered item keeps the number it was written with), quotes, rules,
fenced code, tables, math, and the inline runs, with a line it does not
recognise kept verbatim as a paragraph rather than dropped. Images are not read,
and nested block structure is flattened. Inline bold and italic are parsed and
their markers taken off, but the text is drawn plain, because the atlas holds
one face - as with a theme's `fontStyle`, weight and slant are not faked with
colour. A table whose columns together ask for more than the panel has is drawn
as the source it was written as rather than shredded across the dock. A fenced
block goes through the editor's own tokenizer for the languages it knows (Zig, C
and C++, Python, JavaScript and TypeScript); any other language draws as plain
text rather than wrongly. A message over a megabyte, or one that would produce
more than 4096 blocks, is refused by name and shown wrapped instead of styled.

Three of those are read and not fully drawn, and that is a deliberate floor
rather than an oversight. **Display math is typeset and inline math is not**: a
formula on lines of its own is laid out by the TeX engine and drawn as the
mathematics it is, while a formula inside a sentence draws as the LaTeX that was
written. The reference's inline conversion is a table of some six hundred
commands, and the inline case is where a half-converted formula would show. A
display formula the engine declines to lay out falls back to the same source, so
mathematics never costs the reader the text. A formula is set at the size of the
surrounding text rather than at a size the engine chose, because the glyphs come
from the atlas; and a filled shape wider than its panel is dropped only when it
falls wholly outside it, so the drawing primitives reject at the clip edge where
the glyph path clips exactly. **A link's address is shown but is not
clickable** - the pointer is wired for chips and folds, not for prose runs, so
the address is drawn beside its words and left as text. **A strikethrough is
carried by colour and not by a line through the words**, because the atlas has
one face and nothing to draw a rule with; a struck run is drawn in the muted
role, which is honest about it not being body text without pretending to be a
decoration.

A call's chip is one line: its title and subject are bounded and elided, so a
chip says what the call was rather than everything it carried - the fields
behind it are where the detail is. The reader's open or closed answer for a call
lives in memory for the session, and exporting a transcript is a client API that
no interface control calls yet.

Liveness is sampled rather than reported: the App compares each lane's counters
once a frame, so a turn's duration is accurate to a frame rather than to the
moment the prompt went out, and a stall is only visible while a turn is in
flight - an idle lane reports its state and no silence. The line is fitted to
the columns the dock can draw, and a line with no room loses a whole part, the
subject before the duration, because the end of a stalled line is the number the
reader came for.

## ACP coverage

The scaffold implements a capability-limited ACP v1 stdio client.
It does not guarantee compatibility with every ACP agent or extension.
It supports one active session per configured process and one prompt per session.
A request names one lane: there is no broadcast, and a lane that is not ready
refuses a prompt rather than queueing it, which the editor reports by name.

Missing ACP features include:

- Session resume, and choosing an authentication method from the interface: a
  preset may name the method to use, and a harness that needs a login has the
  methods it offers reported rather than a prompt that asks which one.
- Content types the panel does not draw. Of ACP's six - `text`, `image`,
  `audio`, `resource`, `resource_link` - `text` is drawn as prose and `image` is
  drawn as a picture; audio, embedded resources and resource links are not read
  as such. Only `image` is advertised as a prompt capability, so a prompt
  carries no audio or embedded context; the same rule as everywhere else applies
  to output, where a part that cannot be drawn says what it was rather than
  vanishing.
- Pictures an agent sends are bounded, and the bounds are what a reader meets
  when one is refused. A payload is kept whole only up to 2 MiB after base64 is
  taken off, an image is decoded only up to 4 MP with no side past 4096 (a
  decompression bomb is refused from its header, before anything is inflated),
  and no picture is enlarged: one wider than the dock is scaled down to fit it
  and one smaller is drawn at its own size, with the height capped at twenty
  rows of the panel. Each refusal is named on the line the picture would have
  occupied - the mime type, the size, and which bound it met - because "an image
  was dropped" is not something a reader can act on. A picture is decoded on the
  frame that first shows it; the renderer keeps pictures up to 8 MP in all,
  evicting the least recently drawn, and a session that scrolls past more than
  that re-decodes rather than holding them. A GIF is drawn as its first frame,
  because one picture is drawn where the part arrived and an animation is not
  that. Pictures travel in one direction: the client accepts an image an agent
  sends and draws it, and nothing in the editor attaches one to a prompt.
- A tool call's embedded `terminal` content is drawn, with one bound worth
  naming: the screen is shown at most twelve rows tall, whatever the terminal's
  own height, because a terminal as tall as the panel would push everything else
  out of the transcript. The screen is still a real terminal - it keeps its own
  scrollback and is sized to the panel's width - so the bound is on what is
  drawn rather than on what is kept. The output stays on screen after the agent
  releases the terminal, which is what the protocol asks for: the client's record
  is freed by `terminal/release`, and the editor keeps the screen it parsed, so
  the display does not depend on the process still existing.
- The optional programmatic tool `name` is read where a call's `kind` says
  nothing, and shaping uses it through a small table of words a tool name is
  built from (`read`, `write`, `bash`, `grep`, and the like), matched on whole
  tokens rather than substrings. A name built from none of those words gets the
  generic card: a tool whose name is a house word rather than a common one is
  drawn plainly rather than shaped, which is the honest outcome of not knowing
  what it is. The table is deliberately short - a long one would be a guess about
  other people's naming, and a wrong shape is worse than a plain card.
- A config-option selector UI (the client parses and sets `configOptions` but does not render a selector).
- Tool-specific rich renderers beyond a handful of shapes. A call is drawn
  through a registry that binds a tool's kind to one of five shapes - a file, a
  change, a command, a search, or the generic card - so a read shows its path, a
  command its exit code and its output, and an edit its diff, while a kind no
  shape knows gets the generic card rather than a dump of its JSON. What is
  missing is a renderer for one tool's own semantics: the shapes are shared, so
  a tool whose output means something no shape covers is drawn plainly rather
  than wrongly. The ACP client also does not route agent edits into the review
  queue, so what is waiting there came from a test, a gate, or the person.
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
italic are drawn by shape rather than by a second face, because the atlas is
rasterized from one face - bold is a second strike a fraction of a pixel across
and italic is the same glyph with its top edge leaned. A real bold or italic
face would look better, and none ships with the repository. Inverse and
underline are drawn. A grapheme's first codepoint is drawn and its combining
marks are not, because the atlas maps codepoints rather than shaped runs.

Kitty graphics is parsed by the library and not drawn. The renderer has the path
a terminal image would use - a picture is decoded, uploaded and drawn in the
transcript - but nothing wires a terminal's graphics protocol to it, so a
program that draws in the terminal still draws nothing there. The scrollbar is drawn
only when there is history behind the viewport, and it is the editor's shape
rather than the program's: a terminal that sets an unusual scrollbar style gets
the plain one. Page Up and Page Down go to the program rather than to
scrollback, which is what applications expect.

The terminal needs a PTY, so it exists where `forkpty` does: Windows has no
terminal dock, and `services/pty.zig` names a type there that refuses rather
than a declaration the linker would have to find. The dock starts a shell from
`/etc/shells` when the reader picks one, and the reader's `SHELL` or `/bin/sh`
otherwise: there is no preference for which shell a new tab gets, and an entry
in `/etc/shells` is dropped when the path it names is not there, so the list can
be shorter than the file.

The editor's shortcut table is consulted before the dock sees a key, so a
program running in the terminal cannot be sent the keys the editor claims: there
is no way to deliver Ctrl+C as an interrupt from the dock, and a Ctrl key with
no editor meaning does nothing there rather than reaching the shell. Typed text
and the keys a terminal sends are unaffected.

A shell that reports its own command boundaries with OSC 133 (bash and zsh are
handed a snippet that makes them) leaves the terminal knowing the last command
and what it printed, and `App.terminalCommand` hands that out; no interface
control uses it yet, so a command's output has to be selected by hand to travel
anywhere. A shell the integration does not know runs as it always did, and the
terminal then has a screen of text and no idea which command produced it.

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

A panel is only drawn for a region the editor asks for, and the editor asks for
four: `activity`, `tabs`, `transcript`, and `status`. A panel registered under
any other name draws nothing, and the shipped bundles still register `explorer`,
`header`, and `lanes` panels from the interface those regions belonged to.

## Themes

`--theme <path>` loads a theme in the native format described in
`src/ui/theme.zig`, or a TextMate `.tmTheme` or VS Code colour theme, which are
recognised by their contents rather than their extension. Import is one-way:
nothing writes either format back, and no format is read at runtime. A theme
changes the editor's colours, the terminal palette, and syntax colouring.

What is not covered:

- **Only two importers, and neither is complete.** A `.tmTheme` carries no
  ANSI palette, so its terminal half is left at the default rather than
  invented. A VS Code theme's `semanticTokenColors` is not read, because it is
  keyed by a semantic tokenizer's kinds and this editor classifies lexically.
  Vim, Emacs, Sublime, and the terminal formats (`.itermcolors`, Windows
  Terminal, ghostty) have no importer.
- **A theme without a terminal palette still sends the placeholder one.** The
  push into a live shell is skipped only when no theme was loaded at all, so a
  `.tmTheme`, or a VS Code theme that sets no `terminal.background` or
  `terminal.foreground`, hands the terminal the document default: sixteen ANSI
  entries that are all the background colour. A program that prints in colour -
  a prompt, `ls`, a diff - then prints in the colour of the paper. With no theme
  loaded the emulator keeps its own palette, which is a real one.
- **Bold and italic are parsed and not drawn.** The atlas has one face, so a
  theme's `fontStyle` reaches the scope list and stops there. What a reader
  gains from inline markup is that the markers are stripped; weight and slant
  are not faked with colour.
- **Scope coverage is lexical.** Syntax colouring comes from the editor's own
  scanner, which knows comments, strings, numbers, keywords, and decorators and
  answers with those names. A theme's rule for `entity.name.function` or
  `variable.parameter` matches nothing, because nothing here produces those
  scopes, and such a rule is silently unused.
- **A theme loaded at startup does not follow a display change**, and only the
  twelve chrome roles plus the two diff roles are themeable: the layout,
  spacing, and font size are not part of the format.
