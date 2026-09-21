# Seggs

**A GPU editor for parallel, agent-assisted code work.**

Seggs pairs a VS Code-style workspace with a Zed-like native interface.
The application targets **Zig 0.17.0**, **SDL3**, and the **SDL3 GPU API**.
ACP connects independent agent processes to the right-hand panel.

> **Scaffold status:** The repository contains implementation code, not a production IDE.
> Native compilation, the Zig test suite (304 declared tests), and the ACP transport test now pass on Linux (Zig 0.17.0, SDL3).
> The GPU path renders under software Vulkan (lavapipe); hardware GPU execution remains unverified.
> The Python fixture suite passed 11 tests.
> See [validation](docs/VALIDATION.md) and [limitations](docs/LIMITATIONS.md).

## What is inside

| Area | Implemented baseline |
| --- | --- |
| Native shell | Fullscreen startup, window mode, high-density window, keyboard shortcuts, resizable docks, dark theme |
| GPU path | Batched textured quads, on-demand glyph atlas with fallback faces, upload buffers, clipping, swapchain, Vulkan and Metal shader sources |
| Editor | UTF-8 gap buffer, cursor, mouse selection, clipboard, undo/redo, themeable lexical colors |
| Workspace | Bounded explorer, quick open, command palette, one active file, external-change check before save |
| Themes | A theme document, or an imported TextMate `.tmTheme` or VS Code colour theme, sets the chrome, the terminal palette, and syntax colouring |
| Transcript | Markdown prose, fenced diffs in the theme's diff colours, and tool calls as chips placed where they happened, openable to their fields and diff |
| Display math | A formula the agent wrote is typeset by a TeX engine and drawn as the mathematics it is, in either the one-line or the opened-and-closed form; a formula the engine refuses falls back to its source rather than disappearing |
| ACP | JSON-RPC over newline-delimited stdio, initialization, new sessions, prompts, text/tool/plan updates, cancellation |
| Parallel agents | Up to eight independent processes, per-agent state, separate transcripts, one destination per request |
| Permissions | Explicit one-time approval or rejection, no automatic approval, bounded pending requests |
| Capabilities | Editor-backed filesystem reads and writes, plus client-owned terminals with explicit process ownership and bounded output |
| Integrations | Oh-My-Pi, Codex ACP adapter, Claude ACP adapter, custom argv, local mock |
| Languages | Optional language server: diagnostics in the gutter, F12 definition, Shift+F12 references, Ctrl+I hover; prompts attach the selection and diagnostics |
| QA capture | `--screenshot PATH` writes the last frame in the format the extension names, and `--exercise-NAME` drives a path to the state a person would reach before the capture. `--help` lists both |
| Terminal | Tabs in a dock below the editor, one shell each, emulated by libghostty-vt: open, close, reorder, and switch; the shells this machine offers read from `/etc/shells`; scrollback with reflow on resize, 24-bit and palette color, inverse and underline styles, the Kitty keyboard protocol, mouse tracking and reporting formats, focus events, bracketed paste, and input encoded from the terminal's own modes |
| SeggsC | Extensions describe interface as data, take events, and ask the editor to act; each bundle runs in a context of its own and reloads while the editor runs |
| Layout | Yoga lays out interface an extension describes, sized from the cell metrics so a font or density change moves the chrome with the text, and every dock resizes by dragging its divider |
| Extensions | TypeScript sources bundled by esbuild and evaluated in an embedded QuickJS-NG host with a `seggs` core API |
| Development | Zig core tests, native transport smoke target, screenshot and window-transition gate, Python fixture tests, dependency bootstrap, CI definition for Linux, macOS, and Windows |

The app calls SDL3 GPU functions directly.
It does not use SDL_Renderer, Electron, or a browser view; the terminal is
libghostty-vt's emulator behind the editor's own renderer, not a terminal
widget. SDL3_ttf rasterizes the startup glyph atlas from a system font.
The repository contains no font files.

## Extensions

Higher-level behavior is intended to live in extensions rather than in the core.
An extension is TypeScript that calls a small `seggs` core API; esbuild bundles
each source into a single script that an embedded QuickJS-NG runtime evaluates.

```sh
cd extensions
npm install
npm run build
```

The app loads every bundled script in `extensions/dist` at startup, and reloads
them when the directory changes while it runs, so a bundle can be written and
seen without restarting the editor. When that directory is absent the app runs
normally and reports no extensions loaded, so the JavaScript toolchain is
optional for building and running the editor.

## Build and run

### Prerequisites

The default bootstrap targets Linux or macOS.
Windows requires an external SDL SDK and a Vulkan driver.
The [build guide](docs/BUILD.md) lists system packages and platform details.

Required tools and libraries:

- Zig 0.17.0 (a development build) and Python 3.12 or later.
- Yoga for layout, pinned like the other dependencies and kept behind a `yoga` translate-c module.
- libghostty-vt for the terminal, built by the bootstrap from the pinned Ghostty commit and reached through its C API.
- No font or text libraries beyond SDL_ttf and MicroTex: glyph selection uses the vendored-pinned zignal package, display math is typeset by MicroTex, and the extension host uses quickjs-ng.
- Extensions are written in **SeggsC**, a TypeScript-shaped DSL for the editor ([contract](docs/EXTENSIONS.md)): interface described as data, events, and requests, in a context of its own, reloadable while the editor runs.
- Git, CMake, a C compiler, and pkg-config.
- tinyxml2 development files, which MicroTex reads its resource files with, and a C++17 compiler.
- SDL 3.4.4 and SDL_ttf 3.2.2, or compatible development libraries.
- FreeType development files and an installed monospace font.
- A Vulkan driver and glslangValidator on Linux or Windows.

### Commands

Install the system prerequisites from [docs/BUILD.md](docs/BUILD.md).

```sh
python3 tools/bootstrap.py --install-zig
export PATH="$PWD/.deps/zig:$PATH"
python3 tools/doctor.py
zig build test
zig build integration
zig build run
```

For an existing Zig installation, omit `--install-zig`.

For a windowed session, run this command.

```sh
zig build run -- --windowed
```

For another workspace, run this command.

```sh
zig build run -- --workspace /absolute/path/to/project --file src/main.zig
```

For a theme, run this command.

```sh
zig build run -- --theme themes/monokai.json
```

`--theme` takes a native theme document, a TextMate `.tmTheme`, or a VS Code
colour theme; which one it is comes from the document rather than the file name,
and a theme that fails to load leaves the editor in the palette it already had
and says why in the status bar. [Architecture](docs/ARCHITECTURE.md) describes
the format, and [limitations](docs/LIMITATIONS.md) says what each import leaves
behind.

The app takes `--workspace PATH`, `--file PATH`, `--config PATH`, `--font PATH`,
`--theme PATH`, `--windowed` or `--fullscreen`, `--window-size WIDTHxHEIGHT`,
`--frames N`, and `--screenshot PATH`, which writes the last frame in the format
the extension names. `--help` prints the same list. The `--exercise-*` flags
drive the editor through a scripted session for the screenshot gate.

The app starts no agent automatically.
The default mock uses an absolute script path that is independent of the selected workspace.
Explicit configs retain their argv values without path rewriting.

## First session without an account

Run the mock configuration from the repository root.

```sh
zig build run -- --config config/mock.json
```

1. Select a mock with Ctrl+1, Ctrl+2, or Ctrl+3. That focuses the prompt as well.
2. Press F5 to start it.
3. Enter a prompt.
4. Press Ctrl+Enter to send it to the lane you are on, or Ctrl+Shift+Enter to pick a destination from the lanes that are up.

A prompt that starts with `permission` exercises the permission interface.
A prompt that starts with `tools` exercises the transcript's tool call chips,
which open when clicked.
A prompt that starts with `slow` exercises cancellation.
The mock never accesses workspace files.

## Real agents

| Preset | Launch argv | Integration boundary |
| --- | --- | --- |
| Oh-My-Pi | `omp acp` | Native ACP command |
| Codex | `codex-acp` | `@agentclientprotocol/codex-acp` adapter |
| Claude Code | `claude-agent-acp` | `@agentclientprotocol/claude-agent-acp` adapter |
| Custom | Explicit argv array | Any compatible ACP v1 stdio harness |

The adapter names follow their upstream repositories.
They are not invented flags on `codex` or `claude`.
See [agent setup](docs/AGENTS.md) and the [upstream references](docs/SOURCES.md).

Authentication remains external to Seggs.
An agent preset may name the ACP authentication method to use, in which case the
client sends `authenticate` with it during startup; the login itself and its
credentials belong to the harness.
A harness that needs authentication the client was not told about reports the
methods it offers, and the editor shows them rather than asking a question it
cannot answer.

### Custom harness

Create a trusted configuration file.

```json
{
  "fullscreen": true,
  "agents": [
    {
      "id": "my-agent",
      "name": "My ACP agent",
      "argv": ["/absolute/path/to/agent", "acp"],
      "cwd": "/absolute/path/to/worktree"
    }
  ]
}
```

Load the configuration explicitly.

```sh
zig build run -- --config /absolute/path/to/agents.json
```

Seggs does not load executable settings from a workspace automatically.
The config supports up to eight agents with unique IDs.
The [JSON schema](config/agents.schema.json) describes its structure.

## Keyboard reference

On macOS, Command also activates the Ctrl shortcuts.
Function keys depend on the system keyboard settings.

| Shortcut | Action |
| --- | --- |
| F11 | Toggle fullscreen |
| F12 / Shift+F12 | Jump to the definition under the cursor / list its references |
| Ctrl+P / Ctrl+Shift+P | Quick open / command palette |
| Ctrl+B | Toggle the file list |
| Ctrl+R | Reload the active file from disk |
| Ctrl+S / Ctrl+Q | Save / quit. Quit asks only when something is unsaved: S saves and quits, D discards |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous open buffer |
| Ctrl+W | Close what is in front: the open list, then a terminal tab, then the agent you are on, then a buffer that is not the last one |
| Ctrl+Shift+W | Toggle the compose surface |
| Ctrl+1 through Ctrl+8 | Select an agent and focus the prompt |
| F5 / F6 | Start the selected agent / close it |
| Ctrl+Shift+A | Open an agent, or approve the run step that is waiting on you |
| Ctrl+L | Focus the prompt |
| Ctrl+Enter / Ctrl+Shift+Enter | Send to the current agent / pick a destination from the agents that are up |
| Ctrl+Shift+X | Cancel the current agent's turn |
| Ctrl+I | Show the language server's hover for the symbol at the cursor |
| Alt+Y / Alt+N | Allow once / reject the visible permission request |
| Ctrl+Shift+T | Open a shell from the list this machine offers, in a new terminal tab |
| Ctrl+Shift+Left / Right | Move the terminal tab along the strip |
| Ctrl+` | Open, hide, or show the terminal dock |
| Ctrl+A / Ctrl+C / Ctrl+X / Ctrl+V | Select all / copy / cut / paste, in the editor |
| Ctrl+Z, Ctrl+Shift+Z or Ctrl+Y | Undo / redo, in the editor |
| Arrow keys, Home, End, Delete | Move the cursor, or delete at it; hold Shift to select |
| Mouse drag, wheel | Select text, or scroll the panel under the pointer |
| Escape | Return the keyboard to the editor |

While the review surface is in front its own keys are the plain ones: Up and
Down choose a change, A accepts it, R rejects it, and Escape goes back to the
code.

While the terminal dock has focus, typed text and the keys a terminal sends go
to the shell: arrows, Home and End, Page Up and Page Down, Delete, Escape, and
the function keys are encoded by the emulator from the terminal's own modes, so
application cursor mode and the Kitty protocol mean what the program asked them
to mean. The editor's Ctrl shortcuts are matched first, which is why the dock's
own keys are `Ctrl+`` and `Ctrl+Shift+T`, copy from the terminal is
`Ctrl+Shift+C`, and paste into it is `Ctrl+V`; a Ctrl key the editor does not
claim does nothing there rather than reaching the shell.

The wheel scrolls the terminal's history, or goes to the program when it has
asked for mouse reporting. Page Up and Page Down go to the program rather than
to the scrollback, which is what applications expect.

The prompt accepts text at its end.
It does not yet provide a full text-editor cursor or selection model.

## Boundaries

**Use a disposable worktree.** The save implementation does not preserve all file metadata.
**Do not run untrusted harnesses.** Agent processes inherit the application environment and the user's operating-system permissions.

Independent ACP sessions do not isolate files.
Agents in the same worktree can overwrite each other's changes.
Per-agent `cwd` values support separate worktrees. A worktree service can create worktrees and detect merge conflicts, but the app does not yet wire it into startup.

The client advertises the editor-backed filesystem capability and client-owned terminals, and implements both.
Advertising a capability does not restrict a harness's own tools.
The permission interface controls only the requests that a harness sends through ACP.

## Repository map

```text
build.zig                  Native build, shaders, tests, and run targets
src/main.zig               Zig 0.17 entry point and CLI
src/app.zig                Workspace, input, panels, and commands
src/gpu/                   SDL3 GPU pipeline and runtime atlas
src/editor/                Gap buffer, document, workspace, lexical colors
src/acp/                   Framing, JSON-RPC, process transport, session client, tool calls
src/agents/                Presets and config validation
src/platform/              SDL C declarations and file operations
src/services/              Language server, debug adapter, Git, worktree, terminal sessions, shell and theme importers, PTY
src/ext/                   SeggsC host and the interface description it lays out
src/ui/                    Rect helpers, layout, theme and the theme catalog, display math through MicroTex, markdown, cards, menus, and the Yoga boundary
src/core/                  Grapheme tables, text helpers, and IME composition
shaders/                   GLSL and Metal source
config/                    Presets, schema, mock, and worktree examples
themes/                    Native theme documents, including the Monokai example, and the catalog the theme switcher lists
tools/                     Dependency setup, doctor, mock, repository checks
extensions/                SeggsC bundles and their TypeScript sources
tests/                     Python subprocess tests and the theme import fixtures
docs/                      Build, design, integration, limits, and validation
```

Dependencies are pinned by hash in `build.zig.zon`: zignal for glyph selection
from TrueType tables, quickjs-ng for the SeggsC host, and Yoga for layout. SDL3,
SDL3_ttf, libghostty-vt — the terminal emulator — and MicroTex, the TeX engine
display math is drawn with, are fetched from pinned sources by
`tools/bootstrap.py`, which records the commits it resolved in
`.deps/resolved.json`. SDL3, SDL3_ttf and libghostty-vt are built into
`.deps/install`; MicroTex is compiled by the build from `.deps/src/MicroTex`,
because its own CMake asks for a GUI toolkit it does not need.

The documentation under `docs/` is also a book. Read it in the repository, or
build it and browse the same chapters with search:

```sh
mdbook build   # written to book/, or `mdbook serve` to read it
```

[Architecture](docs/ARCHITECTURE.md) · [Build guide](docs/BUILD.md) · [Agent setup](docs/AGENTS.md) · [SeggsC](docs/EXTENSIONS.md) · [Limitations](docs/LIMITATIONS.md) · [Roadmap](docs/ROADMAP.md) · [Security](SECURITY.md)
