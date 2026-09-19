# Seggs

**A GPU editor for parallel, agent-assisted code work.**

Seggs pairs a VS Code-style workspace with a Zed-like native interface.
The application targets **Zig 0.16.0**, **SDL3**, and the **SDL3 GPU API**.
ACP connects independent agent processes to the right-hand panel.

> **Scaffold status:** The repository contains implementation code, not a production IDE.
> Native compilation and GPU execution remain unverified in the delivery environment.
> The Python fixture suite passed 11 tests.
> See [validation](docs/VALIDATION.md) and [limitations](docs/LIMITATIONS.md).

## What is inside

| Area | Implemented baseline |
| --- | --- |
| Native shell | Fullscreen startup, window mode, high-density window, keyboard shortcuts, dark theme |
| GPU path | Batched textured quads, glyph atlas, upload buffers, clipping, swapchain, Vulkan and Metal shader sources |
| Editor | UTF-8 gap buffer, cursor, mouse selection, clipboard, undo/redo, basic lexical colors |
| Workspace | Bounded explorer, quick open, command palette, one active file, external-change check before save |
| ACP | JSON-RPC over newline-delimited stdio, initialization, new sessions, prompts, text/tool/plan updates, cancellation |
| Parallel agents | Up to eight independent processes, per-agent state, separate transcripts, selected or broadcast prompts |
| Permissions | Explicit one-time approval or rejection, no automatic approval, bounded pending requests |
| Integrations | Oh-My-Pi, Codex ACP adapter, Claude ACP adapter, custom argv, local mock |
| Development | Zig core tests, native transport smoke target, Python fixture tests, dependency bootstrap, Linux CI definition |

The app calls SDL3 GPU functions directly.
It does not use SDL_Renderer, Electron, a browser view, or a terminal renderer.
SDL3_ttf rasterizes the startup glyph atlas from a system font.
The repository contains no font files.

## Build and run

### Prerequisites

The default bootstrap targets Linux or macOS.
Windows requires an external SDL SDK and a Vulkan driver.
The [build guide](docs/BUILD.md) lists system packages and platform details.

Required tools and libraries:

- Zig 0.16.0 and Python 3.12 or later.
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
| Ctrl+L / Escape | Focus prompt / focus editor |
| Ctrl+Enter | Send to the selected ready agent |
| Ctrl+Shift+Enter | Send to every ready agent |
| Ctrl+Shift+X | Cancel the selected turn |
| Alt+Y / Alt+N | Allow once / reject the visible permission request |

The prompt accepts text at its end.
It does not yet provide a full text-editor cursor or selection model.

## Boundaries

**Use a disposable worktree.** The save implementation does not preserve all file metadata.
**Do not run untrusted harnesses.** Agent processes inherit the application environment and the user's operating-system permissions.

Independent ACP sessions do not isolate files.
Agents in the same worktree can overwrite each other's changes.
Per-agent `cwd` values support separate worktrees, but Seggs does not create or merge those worktrees.

The client advertises no editor-backed filesystem or terminal capability.
This declaration does not restrict a harness's own tools.
The permission interface controls only the requests that a harness sends through ACP.

## Repository map

```text
build.zig                  Native build, shaders, tests, and run targets
src/main.zig               Zig 0.16 entry point and CLI
src/app.zig                Workspace, input, panels, and commands
src/gpu/                   SDL3 GPU pipeline and runtime atlas
src/editor/                Gap buffer, document, workspace, lexical colors
src/acp/                   Framing, JSON-RPC, process transport, session client
src/agents/                Presets and config validation
src/platform/              SDL C declarations and file operations
src/services/              Future language/debug service contracts only
shaders/                   GLSL and Metal source
config/                    Presets, schema, mock, and worktree examples
tools/                     Dependency setup, doctor, mock, repository checks
tests/                     Python subprocess tests
docs/                      Build, design, integration, limits, and validation
```

The repository has no Zig package dependencies.
It therefore omits `build.zig.zon` rather than supply a fabricated package fingerprint.
SDL libraries remain external native dependencies.

[Architecture](docs/ARCHITECTURE.md) · [Build guide](docs/BUILD.md) · [Agent setup](docs/AGENTS.md) · [Limitations](docs/LIMITATIONS.md) · [Roadmap](docs/ROADMAP.md) · [Security](SECURITY.md)
