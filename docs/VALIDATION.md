# Delivery validation

Date: September 19, 2026.

## Executed

The Python fixture suite passed all 11 tests.
The suite ran real local subprocesses for its protocol scenarios.
It did not use provider credentials or network services.

Covered scenarios:

- Initialization and session creation.
- Fragmented Unicode and escaped text.
- Three concurrent independent processes.
- One-time permission approval and rejection.
- Cancellation during output and during a permission request.
- Session reuse after cancellation.
- Malformed JSON, unknown requests, protocol mismatch, invalid session setup, and frame limits.

The repository checker validates local imports and Markdown links.
It parses JSON configs and Python source.
It checks Zig delimiters and selected GPU/ACP source contracts.
It does not parse Zig types or compile native code.

## Not executed

| Gate | Delivery status |
| --- | --- |
| `zig build test` | Not executed. Zig 0.16.0 was absent. |
| `zig build integration` | Not executed. Zig and the SDL SDK were absent. |
| `zig build check` | Not executed. The native toolchain was absent. |
| GLSL compilation | Not executed. glslangValidator was absent. |
| Vulkan or Metal display test | Not executed. The app was not compiled. |
| Live Oh-My-Pi, Codex, or Claude turn | Not executed. No live provider integration test ran. |
| Linux CI workflow | Definition supplied. No completed CI run is claimed. |
| macOS or Windows execution | Not executed. |

Native dependency downloads failed in the delivery environment.
No native build result or performance measurement is implied by the source scaffold.

## Native acceptance procedure

Install the prerequisites from [BUILD.md](BUILD.md).

Run the full validation target.

```sh
zig build verify
```

Run the bounded display test.

```sh
zig build run -- --windowed --frames 8
```

Run the local three-agent interface.

```sh
zig build run -- --config config/mock.json
```

Test fullscreen transitions and text edits before a real agent session.
Use a disposable worktree for the first real agent session.

## Result interpretation

A fixture pass means that the Python protocol fixture behaves as tested.
A native integration pass means that the Zig clients exchange messages through SDL process pipes.
A display pass means that a local backend can compile shaders and present frames.
A live-agent pass requires its own recorded adapter version and authentication environment.
