# Seggs

**A GPU editor for parallel, agent-assisted code work.**

Seggs pairs a VS Code-style workspace with a Zed-like native interface.
The application targets **Zig 0.17.0**, **SDL3**, and the **SDL3 GPU API**.
ACP connects independent agent processes to the right-hand panel.

> **Scaffold status:** The repository contains implementation code, not a production IDE.
> Native compilation, core tests, and the ACP transport test now pass on Linux (Zig 0.17.0, SDL3).
> The GPU path renders under software Vulkan (lavapipe); hardware GPU execution remains unverified.
> The Python fixture suite passed 11 tests.
> See [validation](docs/VALIDATION.md) and [limitations](docs/LIMITATIONS.md).

## What is inside

| Area | Implemented baseline |
| --- | --- |
| Native shell | Fullscreen startup, window mode, high-density window, keyboard shortcuts, dark theme |
| GPU path | Batched textured quads, on-demand glyph atlas with fallback faces, upload buffers, clipping, swapchain, Vulkan and Metal shader sources |
| Editor | UTF-8 gap buffer, cursor, mouse selection, clipboard, undo/redo, basic lexical colors |
| Workspace | Bounded explorer, quick open, command palette, one active file, external-change check before save |
| ACP | JSON-RPC over newline-delimited stdio, initialization, new sessions, prompts, text/tool/plan updates, cancellation |
| Parallel agents | Up to eight independent processes, per-agent state, separate transcripts, selected or broadcast prompts |
| Permissions | Explicit one-time approval or rejection, no automatic approval, bounded pending requests |
| Capabilities | Editor-backed filesystem reads and writes, plus client-owned terminals with explicit process ownership and bounded output |
| Integrations | Oh-My-Pi, Codex ACP adapter, Claude ACP adapter, custom argv, local mock |
| Languages | Optional language server: diagnostics in the gutter, F12 definition, Shift+F12 references, Ctrl+I hover; prompts attach the selection and diagnostics |
| Terminal | A shell in a dock below the editor, emulated by libghostty-vt: scrollback with reflow on resize, 24-bit and palette color, inverse and underline styles, the Kitty keyboard protocol, mouse tracking and reporting formats, focus events, bracketed paste, and input encoded from the terminal's own modes |
| SeggsC | Extensions describe interface as data, take events, and ask the editor to act; each bundle runs in a context of its own and reloads while the editor runs |
| Layout | Yoga lays out interface an extension describes, sized from the cell metrics so a font or density change moves the chrome with the text |
| Extensions | TypeScript sources bundled by esbuild and evaluated in an embedded QuickJS-NG host with a `seggs` core API |
| Development | Zig core tests, native transport smoke target, screenshot and window-transition gate, Python fixture tests, dependency bootstrap, Linux CI definition |

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

The app loads every bundled script in `extensions/dist` at startup. When that
directory is absent the app runs normally and reports no extensions loaded, so
the JavaScript toolchain is optional for building and running the editor.

## Build and run

### Prerequisites

The default bootstrap targets Linux or macOS.
Windows requires an external SDL SDK and a Vulkan driver.
The [build guide](docs/BUILD.md) lists system packages and platform details.

Required tools and libraries:

- Zig 0.17.0 (a development build) and Python 3.12 or later.
- Yoga for layout, pinned like the other dependencies and kept behind a `yoga` translate-c module.
- No font or text libraries beyond SDL_ttf: glyph selection uses the vendored-pinned zignal package, and the extension host uses quickjs-ng.
- Extensions are written in **SeggsC**, a TypeScript-shaped DSL for the editor ([contract](docs/EXTENSIONS.md)): interface described as data, events, and requests, in a context of its own, reloadable while the editor runs.
- Git, CMake, a C compiler, and pkg-config.
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

The app starts no agent automatically.
The default mock uses an absolute script path that is independent of the selected workspace.
Explicit configs retain their argv values without path rewriting.

## First session without an account

Run the mock configuration from the repository root.

```sh
zig build run -- --config config/mock.json
```

1. Select each mock with Ctrl+1, Ctrl+2, or Ctrl+3.
2. Press F5 to start each selected mock.
3. Press Ctrl+L to focus the prompt.
4. Enter a prompt.
5. Press Ctrl+Shift+Enter to send the prompt to all ready mocks.

A prompt that starts with `permission` exercises the permission interface.
A prompt that starts with `tools` exercises the transcript's tool call chips.
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
The scaffold does not implement an ACP authentication interface.
An agent that requires authentication through the client needs that extension first.

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
| Ctrl+P / Ctrl+Shift+P | Quick open / command palette |
| Ctrl+B | Toggle explorer |
| Ctrl+S / Ctrl+Q | Save / quit |
| Ctrl+Z / Ctrl+Shift+Z | Undo / redo |
| Ctrl+A / Ctrl+C / Ctrl+X / Ctrl+V | Select all / copy / cut / paste |
| Shift+arrows / mouse drag | Select text |
| Ctrl+1 through Ctrl+8 | Select an agent |
| F5 / F6 | Start / stop the selected agent |
| Ctrl+` | Toggle the terminal dock |
| Ctrl+L / Escape | Focus prompt / focus editor |
| Ctrl+Enter | Send to the selected ready agent |
| Ctrl+Shift+Enter | Send to every ready agent |
| Ctrl+Shift+X | Cancel the selected turn |
| Alt+Y / Alt+N | Allow once / reject the visible permission request |

While the terminal dock has focus the keyboard belongs to the shell: only
Ctrl+` is kept by the editor, so Ctrl+C, Ctrl+Z, and the rest reach the program
running there. The wheel scrolls the terminal's history, or goes to the program
when it has asked for mouse reporting.

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
src/acp/                   Framing, JSON-RPC, process transport, session client
src/agents/                Presets and config validation
src/platform/              SDL C declarations and file operations
src/services/              Language server, debug adapter, git, worktree, and PTY clients
src/ext/                   SeggsC host and the interface description it lays out
src/ui/                    Rect helpers, theme colors, and the Yoga boundary
shaders/                   GLSL and Metal source
config/                    Presets, schema, mock, and worktree examples
tools/                     Dependency setup, doctor, mock, repository checks
extensions/                SeggsC bundles and their TypeScript sources
tests/                     Python subprocess tests
docs/                      Build, design, integration, limits, and validation
```

Dependencies are pinned by hash in `build.zig.zon`: zignal for glyph selection
from TrueType tables, quickjs-ng for the SeggsC host, and Yoga for layout. SDL3
and SDL3_ttf are built from source into `.deps/install` by `tools/bootstrap.py`.

The documentation under `docs/` is also a book. Read it in the repository, or
build it and browse the same chapters with search:

```sh
mdbook build   # written to book/, or `mdbook serve` to read it
```

[Architecture](docs/ARCHITECTURE.md) · [Build guide](docs/BUILD.md) · [Agent setup](docs/AGENTS.md) · [SeggsC](docs/EXTENSIONS.md) · [Limitations](docs/LIMITATIONS.md) · [Roadmap](docs/ROADMAP.md) · [Security](SECURITY.md)
