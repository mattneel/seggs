# Delivery validation

Date: September 21, 2026.

## Executed

Every result below that names a command comes from running it on this Linux host,
in one session, against the tree at that date. Two kinds of row are not runs of
that kind: the workflow rows describe definitions, and the live-agent rows need
their own credentials and adapter versions. The toolchain is Zig 0.17.0
(`0.17.0-dev.1970+67f39b551`, the version `.zigversion` pins), SDL 3.4.4,
SDL_ttf 3.2.2, and libghostty-vt built by `tools/bootstrap.py` from the pinned
Ghostty commit. The renderer is exercised under Xvfb with the lavapipe software
driver and the Khronos validation layer.

The counts are the ones the runners printed. `zig build test-native` and
`zig build test` are cached by Zig, so a cached run reports nothing; the counts
below come from a run with a fresh local cache directory, which re-executes both
suites.

| Gate | Result |
| --- | --- |
| `zig build test` | 121 core Zig tests pass. |
| `zig build check` | The native UI compiles and links against SDL3, SDL3_ttf, and libghostty-vt. |
| `zig build test-native` | 105 tests pass: save roundtrip, `SaveTemporary`, `FileRename`, save through a symlink, save into a read-only directory, multi-document workspace, external-edit detection and reload, review apply/conflict/preview, worktree create/conflict, git status/diff, LSP diagnostics, definition, references, hover, and frame escaping, DAP breakpoint, stack, variables, and resume, transport queue item and byte bounds, partial-write and full-pipe delivery, stalled-sink failure, PTY shell output and exit, terminal size at birth and after a change, a shell's first prompt, tab close and reorder, shell integration for bash and zsh, the emulator's screen, colors, styles, scrollback, scrollbar, selection, title, and key/paste encoders, a shell's own command markers and what they let the terminal report, shaper codepoint-to-glyph mapping against the rasterizer's own selection, Yoga flex layout and measured leaves, extension descriptions parsing, laying out, and reporting focusable nodes, prompt attachment of real language-server diagnostics, a bundle read from the file system, and a tool call as a record with a transcript offset. |
| `zig build verify` | Exit 0: runs the core tests, the ACP integration, the native tests, and the native compile. |
| `zig build integration` | Seven checks pass against the local mock: the three native ACP transports, stream isolation, permission rejection, cancellation, and session reuse; a configured authentication method authenticating and a refusal naming the harness's offered methods; early agent exit reaching `FAILED`; `fs/read_text_file` through the capability broker; `fs/write_text_file`; `terminal/create` running an isolated command, reporting its exit, and releasing it; and `session/set_config_option`. |
| GLSL compilation | `glslangValidator` compiles both UI shaders to SPIR-V as part of the build. |
| Vulkan display smoke | `VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json SDL_VIDEODRIVER=x11 xvfb-run -a zig build run -- --windowed --frames 8` exits 0, and the run reports `atlas: 98 glyphs packed, 0 placeholder hits` and `extensions: 5 loaded`. |
| `compare` | Two offscreen captures of the same build must agree, and a capture must contain drawn content rather than a flat clear color. This run: `1440x900, 1769 distinct colors, 917435 background pixels` for both, and `max channel delta 0, 0/1296000 pixels differ (0.0000%)`. The capture covers the layout the frame was drawn for, so a capture at the wrong size cannot pass unnoticed. |
| `text` | Five runs of 60 glyphs are measured against the advance the app reports for its own atlas: `60 glyphs drew 568px, expected about 570px at advance 9.5`. This catches captures taken at the wrong size and glyph quads built from the wrong metrics, both of which still produce a plausible-looking frame. |
| `baseline` | A rasterized glyph is cropped to its ink, so the atlas records where that ink sits relative to the pen and the baseline. The gate renders a line of `H` above a line of `.` and measures both: `60 capitals on row 106 beside their line number, 60 periods on row 128 one line below`. Comparing the fixture only with itself cannot catch a shift, because every fixture line moves together. |
| `fallback` | One fixture per script family against an ASCII baseline, which needs a face covering CJK installed (the workflows install one): `Cyrillic and Greek packed 11 further glyph(s) for 11 uncovered codepoint(s), 0 placeholder hits` and `CJK packed 7 further glyph(s) for 7 uncovered codepoint(s), 0 placeholder hits`. One script family alone would not prove the chain covers another. |
| `ime` | Composition text is held in `src/core/preedit.zig` and drawn at the cursor with the segment the input method selected highlighted and an underline beneath the whole composition. This run: `composition text drawn across 11 rows, commit inserted 7 byte(s)`. The gate drives real editing and text input events and checks that committing inserts exactly the committed bytes. |
| `panel` | `5 extension(s) loaded, click reached panel transcript, explorer row opened agents.example.json, agent tab clicked Local mock, jump lists chose and sent to Local mock, hover reported on tabs`. Five extensions describe their panels in TypeScript, and the editor asks for four regions - `activity`, `tabs`, `transcript`, and `status` - so those are what the run draws from descriptions. The same run drives both request kinds through real SDL events (a click on an explorer row opens a file through `seggs.editor.action`; a click on a tab asks through `seggs.agent.action`), routes a click to the deepest node under the pointer, and reports a pointer move only when the node under it changes. Requests are applied between frames, so a handler never disturbs the frame it runs in. |
| `extensions` | `a broken bundle reported "SyntaxError: expecting ';'", reloading picked up the fix at generation 2`. The editor runs in a temporary workspace with one working bundle and one that cannot parse; the broken one must be reported with its message in `.seggs/extensions.json`, and fixing it while the editor runs must reload it. A loop an agent cannot close is not a loop. |
| `narrow` | The whole event exercise again at 860x600: `5 extension(s) at 860x600, rail handled sidebar`. Below the breakpoints the file list and the agent column are dropped and the editor takes their space; the panels that remain must still lay out and take events. |
| `density` | `scale 2.00, logical 900x640 with a 900x640 backbuffer, transitions survived`. The editor asks for a high-density window and a CI runner reports a scale of one, so the flag alone would never be exercised: the gate runs with an X11 content scale of two, where the frame loop must still finish. |
| Vulkan validation | The gate runs every app invocation with `VK_LAYER_KHRONOS_validation` enabled whenever the layer is installed, and requires it when `CI` is set, so "no validation errors" is a check the runs can fail rather than a message that cannot appear. |
| Terminal emulation | `src/services/vt.zig` wraps libghostty-vt: the screen, cursor, colors, and modes come from the render state, and input is encoded by the library. Native tests feed it escape sequences and assert the grid, that a Ctrl key becomes its control byte, that the application cursor mode changes the arrow keys, that the Kitty protocol reports a modified key as its codepoint, that focus and bracketed paste are silent until the program asks, that a mouse report carries the cell the caller named, and that the viewport scrolls into history and back. |
| `terminal` | The dock is opened, which starts the user's shell, a command is typed through the same path the keyboard takes, and the shell's answer must appear on the emulator's screen; the shell must also be one that marks its own commands: `terminal: the shell marked its command: history-27`. |
| `terminal paints` | `a real shell ran in the dock, its answer reached the screen, and the dock drew 3479 lit pixels`: a live shell must draw something, and what it draws must be visible in the frame rather than merely present in the emulator. |
| `run` | A run exists without a panel being open, and a step actually runs: `reviewed.zig started with 3 steps and 1 artifact(s) at plan, then a harness answered and approve recorded 52 bytes of review, and a proposed change was accepted with 0 left waiting`. |
| `compose` | `workspace as plan \| implement \| review`: a workflow reads left to right and says what travels along it. |
| `tabs` | The terminal's tabs agree on which is showing after adding, moving, and closing: `2 open after adding three and closing one, showing 1, and selecting copied 1 byte(s)`. |
| ACP authentication | An agent preset may name an authentication method. `zig build integration` covers both directions against the mock: a configured method reaching a ready session, and a refusal that names the methods the harness offered. |
| Clean run | The scale fixture run must also produce no Vulkan validation errors and no allocator leak report at shutdown. A render pass that disagrees with the pipeline's target format, or a resource released after its device, fails here. |
| `window` | The gate runs `--exercise-window`: a resize must reach the window, and minimize, restore, and fullscreen transitions must leave the frame loop rendering. This run: `3 transitions exercised, resize reached 900x640, refusals: none`. Refusals are reported rather than failed, because a window manager is not always present. |
| Extension host | The bundled TypeScript extension loads from `extensions/dist`, evaluates in QuickJS-NG, and reports `seggs 0.2.0 extension ready` through the `seggs.status` callback. |
| Shaping | `src/gpu/shaper.zig` maps codepoints to font glyph indices through zignal, and a native test confirms those indices select the same glyph as rasterizing by codepoint, so the two font paths cannot disagree. Advances stay with the rasterizer's hinted metrics, so text keeps its columns. |
| `tool calls` | A call is drawn where it happened in the transcript rather than at the end of the lane's text, and it is an object a reader scans: a chip naming the tool and its state, with what it was about beside it and the detail behind it. The gate runs a turn carrying the four shapes a chip draws and clicks the edit's chip through a real SDL mouse event: `4 chips drawn (read ✓:src/app.zig \| edit ✓:src/ui/tool_call.zig \| run ✗:zig build verify \| run ●:zig build test); the click opened the edit`. A chip that stopped naming its state, or one no click can open, is a call the reader cannot see into. |
| Language server | With `lsp` configured, opening a file starts the server and reports its diagnostics; F12, Shift+F12, and Ctrl+I resolve definition, references, and hover against the mock server. |
| Debug adapter | The DAP client launches with a breakpoint, reports the stack trace and variables for the stopped frame, and resumes with `continue` and `next` against the mock adapter. |
| Live Oh-My-Pi turn | `zig build integration-omp` completes initialize, session, and prompt against the real Oh-My-Pi ACP agent (18.2.6), and the transcript carries the word the prompt asked for, so an error frame cannot pass as a turn. |
| Live Claude Code turn | `zig build integration-claude` does the same against the real Claude Agent (`claude-agent-acp` 0.79.0). |
| `python3 -m unittest discover -s tests -v` | All 11 fixture tests pass: `Ran 11 tests in 0.709s`, `OK`. |
| `.github/workflows/ci.yml` | Four jobs. `core` installs Zig, runs the Zig core tests, the Python fixtures, the repository contracts, and builds the book. `native-linux` bootstraps SDL, runs `verify`, builds the extension bundles, runs the screenshot gate under Xvfb with the lavapipe driver and the Khronos validation layer, then the display smoke. `macos` does the same through Cocoa and Vulkan-on-Metal via MoltenVK, which is the Metal path this repository can exercise; macOS builds the Metal shader rather than SPIR-V. `windows` prepares SDL3, SDL3_ttf, and glslang from the SDK recipe in BUILD.md, compiles the shaders with the command the build would run, and runs `verify`, which builds the editor, runs the native tests, and passes the ACP integration suite there. The pinned toolchain, the Zig package cache, each platform's SDK downloads, and esbuild's package tree are cached, keyed on the pin files. A failing comparison reports the span the captures differ in, a per-eighth histogram, and uploads both frames. |
| `.github/workflows/pages.yml` | Builds the book and deploys it to GitHub Pages at <https://mattneel.github.io/seggs/>. |
| `python3 tools/check_repo.py` | `PASS: 110 repository files, 50 Zig sources, 175 declared Zig tests` and `PASS: relative imports, JSON configs, Python syntax, local links, GPU/ACP source contracts, CI definition targets, and font exclusion`. It resolves every `zig build` target and every script the CI workflow names against the tree, so a renamed target cannot wait for a runner to fail. It checks Zig delimiters and selected GPU/ACP source contracts; it does not parse Zig types or compile native code. |
| `zig fmt --check build.zig src` | Clean except `src/main.zig`, where the pinned formatter rewrites one call as `@backingInt(reading.phase)` where the source says `@intFromEnum(reading.phase)`. The two spellings are the same builtin, and the file compiles as written; this is the one row in this table that does not pass. |
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

### Failure injection

Allocation failure is exercised with `std.testing.checkAllAllocationFailures`,
which fails every allocation in sequence and asserts a clean `error.OutOfMemory`
with no leak and no partial state:

- `src/editor/gap_buffer.zig` — growth across multiple insertions.
- `src/editor/document.zig` — replace, insert, undo, and redo.
- `src/acp/framing.zig` — fragmented and coalesced frame decoding.
- `src/core/preedit.zig` — composition updates and commits.

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
| CI workflow | Definition supplied. No completed CI run is claimed. |
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

Run the screenshot gate. It needs a display and a Vulkan driver; on a headless
Linux host the gate wraps each run in `xvfb-run`, picks the lavapipe ICD, and
enables the Khronos validation layer when it is installed.

```sh
zig build screenshot
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
