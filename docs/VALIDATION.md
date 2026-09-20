# Delivery validation

Date: September 20, 2026.

## Executed

The native build now compiles and the runnable acceptance gates pass on Linux.
These results supersede the earlier scaffold note that the delivery toolchain was absent.
The toolchain is present through mise and the dependency bootstrap completed.

Executed on Linux (Zig 0.17.0, SDL 3.4.4, SDL_ttf 3.2.2):

| Gate | Result |
| --- | --- |
| `zig build test` | 33 core Zig tests pass. |
| `zig build check` | The native UI compiles and links against SDL3 and SDL3_ttf. |
| `zig build test-native` | 45 tests pass: save roundtrip, `SaveTemporary`, `FileRename`, save through a symlink, save into a read-only directory, multi-document workspace, external-edit detection, review-queue apply, worktree create/conflict, git status/diff, LSP diagnostics, LSP definition/references/hover, LSP frame escaping, DAP breakpoint, DAP stack/variables/resume, transport queue item and byte bounds, partial-write and full-pipe delivery, stalled-sink failure, PTY shell output, shaper codepoint-to-glyph mapping against the rasterizer's own selection, Yoga flex layout and measured leaves, extension descriptions parsing, laying out, and reporting focusable nodes, prompt attachment of real language-server diagnostics, a bundle read from the file system loading and running, the explorer leaving generated directories out of the file list, and transitively-imported editor core tests. |
| `zig build integration` | Native ACP transports pass stream isolation, permission rejection, cancellation, session reuse, early-exit handling, fs read/write, terminal create/output/exit/release, and session config against the local mock. |
| GLSL compilation | `glslangValidator` compiles both UI shaders to SPIR-V as part of the build. |
| Vulkan display smoke | `zig build run -- --windowed --frames 8` under Xvfb with the lavapipe software ICD renders 8 frames and exits 0. |
| Screenshot comparison | `zig build screenshot` renders two offscreen frames through `--screenshot` and compares the readbacks: identical pixels, and a frame that must contain drawn content rather than a flat clear color. The capture covers the layout the frame was drawn for, so a capture at the wrong size cannot pass unnoticed. |
| Text scale | The same gate renders a fixture of five runs of 60 glyphs and measures the drawn run against the advance the app reports for its own atlas. This catches captures taken at the wrong size and glyph quads built from the wrong metrics, both of which still produce a plausible-looking frame. |
| Glyph baseline | A rasterized glyph is cropped to its ink, so the atlas records where that ink sits relative to the pen and the baseline. The gate renders a line of `H` above a line of `.` and measures both: the capitals must bottom out on their line's baseline, the periods one line pitch below, and both must agree with the line number drawn beside them through the text helper that adds the ascent. Comparing the fixture only with itself cannot catch a shift, because every fixture line moves together. |
| Extension panel | `zig build screenshot` runs the app with five extensions that describe their panels in TypeScript. The explorer, tab strip, header line, status bar, agent lanes, and empty-transcript panel are all drawn from descriptions; every one of them was drawn by the editor before. Providers are called on every frame with the size of the region they fill, so a panel showing live state stays current. |
| Extension action | The same run drives both kinds of request through real SDL events: Tab and Enter, then a click on an explorer row, opens a file through `seggs.editor.action`, and a click on a lane asks through `seggs.agent.action` for an agent to be activated. Both are applied by the editor between frames, so a handler never disturbs the frame it runs in, and the result is reported. |
| Extension events | The same run clicks the drawn panel through a real SDL mouse event: the click is hit tested against the panel's laid-out nodes, the deepest node is reported to the handler the extension registered, and the message that handler writes reaches the status bar. A click that never reaches a handler fails the gate. |
| Extension reload | `zig build screenshot` runs the editor in a temporary workspace with one working bundle and one that cannot parse. The broken bundle must be reported with its message in `.seggs/extensions.json`, and writing a fixed bundle while the editor runs must reload it: the report has to show both loaded and a higher generation. A loop an agent cannot close is not a loop. |
| Responsive shell | `src/ui/layout.zig` is sized from the cell metrics, so a different font moves the bars and rails with the text, and it drops columns as the window narrows: below 1040 the file list, below 880 the agent column. A unit test tiles every width and height pair it can be given, and `zig build screenshot` runs the whole event exercise again at 860x600 to check the panels that remain still lay out and take events. |
| Pointer feedback | The same run moves the pointer over a row and requires the panel that drew it to be told. Only a change is reported, and panels use it to respond before a click. |
| High-density display | The editor asks for a high-density window, and a CI runner reports a scale of one, so the flag alone would never be exercised. The app reports the scale beside the sizes it drew, and the gate runs the window transitions again with an X11 content scale of two, where the frame loop must still finish. |
| Vulkan validation | The gate runs every app invocation with `VK_LAYER_KHRONOS_validation` enabled whenever the layer is installed, and requires it when `CI` is set, so "no validation errors" is a check the runs can fail rather than a message that cannot appear. |
| Terminal emulation | `src/services/vt.zig` wraps libghostty-vt: the screen, cursor, colors, and modes come from the render state, and input is encoded by the library. Native tests feed it escape sequences and assert the grid, that a Ctrl key becomes its control byte, that the application cursor mode changes the arrow keys, that the Kitty protocol reports a modified key as its codepoint, that focus and bracketed paste are silent until the program asks, that a mouse report carries the cell the caller named, and that the viewport scrolls into history and back. |
| Terminal surface | `zig build screenshot` opens the dock, which starts the user's shell, types a command through the same path the keyboard takes, and requires the shell's answer to appear on the emulator's screen: the round trip is what no single component could fake. The gate also requires the frame loop to finish with the terminal open. |
| ACP authentication | An agent preset may name an authentication method. `zig build integration` covers both directions against the mock: a configured method reaching a ready session, and a refusal that names the methods the harness offered. |
| Clean run | The scale fixture run must also produce no Vulkan validation errors and no allocator leak report at shutdown. A render pass that disagrees with the pipeline's target format, or a resource released after its device, fails here. |
| Window transitions | The same gate runs `--exercise-window`: a resize must reach the window, and minimize, restore, and fullscreen transitions must leave the frame loop rendering. Refusals are reported rather than failed, because a window manager is not always present. |
| Glyph fallback | `zig build screenshot` renders one fixture per script family against an ASCII baseline, which needs a face covering CJK installed (the workflows install one): Cyrillic and Greek pack 11 further glyphs for 11 uncovered codepoints, CJK packs 7 for 7, and neither reports a placeholder hit. One script family alone would not prove the chain covers another. |
| Extension host | The bundled TypeScript extension loads from `extensions/dist`, evaluates in QuickJS-NG, and reports `seggs 0.2.0 extension ready` through the `seggs.status` callback. |
| Shaping | `src/gpu/shaper.zig` maps codepoints to font glyph indices through zignal, and a native test confirms those indices select the same glyph as rasterizing by codepoint, so the two font paths cannot disagree. Advances stay with the rasterizer's hinted metrics, so text keeps its columns. |
| IME composition | Composition text is held in `src/core/preedit.zig` and drawn at the cursor with the segment the input method selected highlighted and an underline beneath the whole composition. The screenshot gate drives real editing and text input events: it checks the reported composition and selection, that the composition text reaches the frame rather than only its underline, and that committing inserts exactly the committed bytes. |
| Language server | With `lsp` configured, opening a file starts the server and reports its diagnostics; F12, Shift+F12, and Ctrl+I resolve definition, references, and hover against the mock server. |
| Debug adapter | The DAP client launches with a breakpoint, reports the stack trace and variables for the stopped frame, and resumes with `continue` and `next` against the mock adapter. |
| Live Oh-My-Pi turn | `zig build integration-omp` completes initialize, session, and prompt against the real Oh-My-Pi ACP agent (18.2.6), and the transcript carries the word the prompt asked for, so an error frame cannot pass as a turn. |
| Live Claude Code turn | `zig build integration-claude` does the same against the real Claude Agent (`claude-agent-acp` 0.79.0). |
| `python3 -m unittest discover -s tests -v` | All 11 fixture tests pass. |
| `.github/workflows/ci.yml` | Four jobs. `core` installs Zig, runs the Zig core tests, the Python fixtures, the repository contracts, and builds the book. `native-linux` bootstraps SDL, runs `verify`, builds the extension bundles, runs the screenshot gate under Xvfb with the lavapipe driver and the Khronos validation layer, then the display smoke. `macos` does the same through Cocoa and Vulkan-on-Metal via MoltenVK, which is the Metal path this repository can exercise; macOS builds the Metal shader rather than SPIR-V. `windows` prepares SDL3, SDL3_ttf, and glslang from the SDK recipe in BUILD.md, compiles the shaders with the command the build would run, and runs `verify`, which builds the editor, runs the native tests, and passes the ACP integration suite there. The pinned toolchain, the Zig package cache, each platform's SDK downloads, and esbuild's package tree are cached, keyed on the pin files. A failing comparison reports the span the captures differ in, a per-eighth histogram, and uploads both frames. |
| `.github/workflows/pages.yml` | Builds the book and deploys it to GitHub Pages at <https://mattneel.github.io/seggs/>. |
| `python3 tools/check_repo.py` | Repository structure and source contracts pass, including the CI definition: every build step and script the workflow names must exist, so a renamed target cannot wait for a runner to fail. |
| `zig fmt --check build.zig src` | Canonical formatting is clean. |
| Book | `mdbook build` turns the chapters under `docs/` into a browsable book with a search index. The repository checker requires every `docs/*.md` to be listed in `docs/SUMMARY.md`, so a chapter cannot exist in the repository and be missing from the book. |

The Python fixture suite ran real local subprocesses for its protocol scenarios.
It did not use provider credentials or network services.

Covered scenarios:

- Initialization and session creation.
- Fragmented Unicode and escaped text.
- Three concurrent independent processes.
- One-time permission approval and rejection.
- Cancellation during output and during a permission request.
- Session reuse after cancellation.
- Malformed JSON, unknown requests, protocol mismatch, invalid session setup, and frame limits.

### Compile fixes

The native build did not compile on Zig 0.16.0 until these defects were corrected:

- `src/acp/client.zig` — a local `start` variable shadowed the `Client.start` method.
- `src/gpu/renderer.zig` — `u0` and `v0` shadowed the `u0` primitive type.
- `src/gpu/renderer.zig` — `1.5 / Atlas.width` divided a `comptime_float` by a `comptime_int`.
- `src/platform/files.zig` — `defer if (!closed) _ = c.fclose(file);` was not a valid `defer` expression.

### Failure injection

Allocation failure is exercised with `std.testing.checkAllAllocationFailures`,
which fails every allocation in sequence and asserts a clean `error.OutOfMemory`
with no leak and no partial state:

- `src/editor/gap_buffer.zig` — growth across multiple insertions.
- `src/editor/document.zig` — replace, insert, undo, and redo.
- `src/acp/framing.zig` — fragmented and coalesced frame decoding.

Temporary-file replacement is exercised by the native filesystem tests in
`src/native_tests.zig`: the success roundtrip, `SaveTemporary` on a missing
directory, and `FileRename` onto an existing directory.

The repository checker validates local imports and Markdown links.
It resolves every `zig build` target and every script named by the CI workflow against the build and the tree.
It parses JSON configs and Python source.
It checks Zig delimiters and selected GPU/ACP source contracts.
It does not parse Zig types or compile native code.

## Not executed

| Gate | Delivery status |
| --- | --- |
| Metal display test | Not executed. Requires macOS. |
| Hardware Vulkan validation | Not executed. The delivery environment has no hardware GPU. |
| Codex turn | Not executed. The `codex-acp` adapter exits silently on startup in this environment. |
| Linux CI workflow | Definition supplied. No completed CI run is claimed. |
| macOS or Windows execution | Not executed. |

The renderer is verified with software Vulkan (lavapipe) under Xvfb.
Hardware Vulkan, Metal, macOS, and Windows remain unverified.

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
