# Upstream references

The scaffold used these primary references on September 19, 2026.
These links describe upstream interfaces, not proof of local compilation or live-agent tests.
The repository does not bundle third-party source or font files. Its one vendored
collection is theme data, and its origin, licence, and commit are recorded under
[Theme provenance](#theme-provenance).

| Reference | Design use |
| --- | --- |
| [Zig 0.17.0 devlog](https://ziglang.org/devlog/2026/) | The reworked build system (maker/configurer split, package management in the build runner) and the new `@bitCast` semantics |
| [Official Zig download manifest](https://ziglang.org/download/index.json) | Exact release archive and SHA-256 lookup |
| [SDL 3.4.4 source](https://github.com/libsdl-org/SDL/tree/release-3.4.4) | Fixed native library baseline |
| [SDL_ttf 3.2.2 source](https://github.com/libsdl-org/SDL_ttf/tree/release-3.2.2) | Fixed glyph rasterization baseline |
| [zignal](https://github.com/arrufat/zignal) | TrueType parsing, glyph indices, kerning, and text layout for `src/gpu/shaper.zig` |
| [Ghostty](https://github.com/ghostty-org/ghostty) | libghostty-vt: terminal parsing, screen state, and the input encoders behind `src/services/vt.zig` |
| [Yoga](https://github.com/facebook/yoga) | Flexbox layout for interface an extension describes, behind `src/ui/yoga.h` |
| [MicroTex](https://github.com/NanoMichael/MicroTex) | The TeX engine behind display math: layout of atoms, boxes and glue, reached through `src/ui/microtex.h` |
| [tinyxml2](https://github.com/leethomason/tinyxml2) | MicroTex reads its resource mappings from XML, and this is the parser it uses. A system package, like FreeType for SDL_ttf |
| [zig-quickjs-ng](https://github.com/mattneel/zig-quickjs-ng) | Zig bindings to QuickJS-NG, the engine the SeggsC host embeds |
| [SDL GPU device](https://wiki.libsdl.org/SDL3/SDL_CreateGPUDevice) | Backend selection and device ownership |
| [SDL GPU shader](https://wiki.libsdl.org/SDL3/SDL_CreateGPUShader) | Shader formats and resource bindings |
| [SDL process creation](https://wiki.libsdl.org/SDL3/SDL_CreateProcessWithProperties) | Argv, working directory, and process pipes |
| [SDL process input](https://wiki.libsdl.org/SDL3/SDL_GetProcessInput) | Partial writes |
| [SDL process output](https://wiki.libsdl.org/SDL3/SDL_GetProcessOutput) | Nonblocking reads |
| [SDL rename](https://wiki.libsdl.org/SDL3/SDL_RenamePath) | Temporary-file replacement |
| [ACP v1 transports](https://agentclientprotocol.com/protocol/v1/transports) | Newline-delimited stdio JSON-RPC |
| [ACP v1 initialization](https://agentclientprotocol.com/protocol/v1/initialization) | Version and capability negotiation |
| [ACP v1 session setup](https://agentclientprotocol.com/protocol/v1/session-setup) | Session creation and working directory |
| [ACP v1 tool calls](https://agentclientprotocol.com/protocol/v1/tool-calls) | Tool updates and permission outcomes |
| [Oh-My-Pi](https://github.com/can1357/oh-my-pi) | Native `omp acp` integration and package workflow |
| [Codex ACP adapter](https://github.com/agentclientprotocol/codex-acp) | `@agentclientprotocol/codex-acp` and `codex-acp` |
| [Claude ACP adapter](https://github.com/agentclientprotocol/claude-agent-acp) | `@agentclientprotocol/claude-agent-acp` and the Claude Agent SDK boundary |
| [Claude adapter manifest](https://github.com/agentclientprotocol/claude-agent-acp/blob/main/package.json) | Executable name and Node.js requirement |

MicroTex has no CMake step here. Its own build requires a GUI backend on Linux
- gtkmm or Qt - and the library has no such dependency: its base source list is
seventy-eight C++ files that compile against a C++17 compiler and tinyxml2
alone, and the drawing comes from the editor through the library's own abstract
`Graphics2D`. `build.zig` compiles those sources and `src/ui/microtex_shim.cpp`
is the backing that answers that interface, so no desktop toolkit reaches a
headless build.

**Its fonts are not font files.** The thirty-five faces the engine sets
mathematics in are C++ source - `src/res/font/*.def.cpp` - compiled in with the
rest, so committing a build of it would still not put a font binary in the
repository. They are not committed here either way: the sources are fetched into
`.deps/`, which is ignored, the way the SDL and libghostty pins are.

The install commands intentionally leave provider adapter versions external.
A downstream release needs tested adapter version pins and compatibility results.

## Theme provenance

`themes/monokai.json` is derived from Monokai, the colour scheme Wimer
Hazenberg published for TextMate and Sublime Text and which is now carried by
most editors. Its colours are the widely published ones for that scheme; the
document is written in this repository's own format rather than copied from a
theme file, and its syntax rules name the scopes `src/editor/highlight.zig`
actually produces.

The two files under `tests/fixtures` exist to exercise the importers: a
`monokai.tmTheme` for the TextMate reader and a `night-owl.json` for the VS Code
one. Each is a faithful sample of its format - an XML plist with a settings
array, and a JSON document with `colors` and `tokenColors` - written to be read
by those readers rather than a copy of a licensed theme distributed as a whole.
They are test input, not shipped themes: nothing but the tests under
`src/services/theme_tm.zig` and `src/services/theme_vscode.zig` reads them.

## The vendored theme catalog

`themes/catalog/` is the theme collection Shiki distributes as `tm-themes`,
vendored whole so the editor ships a catalog of themes rather than one example.
It came from
[shikijs/textmate-grammars-themes](https://github.com/shikijs/textmate-grammars-themes)
at commit `3d55b46a065be774617e70c4c621a468c6824631` (September 20, 2026),
directory `packages/tm-themes/themes`. The directory holds 65 JSON files at that
commit, and all 65 are here under their upstream names. The files are unmodified:
none has been hand-edited, reformatted, or renamed, and a file that needs a
change is a file to re-vendor rather than to patch.

Byte-identity with upstream was checked against the commit itself rather than
against a fresh download: every file's `git hash-object` equals the blob SHA the
GitHub contents API reports for that path at that commit, for all 65 files, with
no file missing and none extra. Re-vendoring should repeat that comparison, and
`themes/catalog` is scanned as a whole by `src/ui/theme_catalog.zig`, whose test
suite fails if the collection is incomplete.

The collection is distributed by Shiki under the MIT licence (© Pine Wu and
Anthony Fu), but the themes in it are not Shiki's: each is covered by the licence
of the project it was converted from, and `tm-themes` carries the per-file notices
in its `NOTICE` file, which is the authority for the list below. Of the 65 files,
59 are MIT, five are Apache-2.0 (the `material-theme*` files, from
[antfu/vsc-material-theme](https://github.com/antfu/vsc-material-theme)), and one,
`aurora-x.json` (from [marqu3ss/Aurora-X](https://github.com/marqu3ss/Aurora-X)),
is GPL-3.0. That last file is the only one here whose licence is not permissive:
it is vendored because the collection was taken whole, and it is named here so
that the decision is visible rather than discovered later. A theme is colour
values, but the file is licensed work, and a downstream release that cannot carry
GPL-3.0 should delete that one file rather than edit it.

The catalog files are read by the same importers as any other theme document -
`src/ui/theme_catalog.zig` decides the format from the document's own contents -
and all 65 of them import. Vendoring them is what proved that, because five did
not at first: `rose-pine.json`, `rose-pine-dawn.json`, `rose-pine-moon.json` and
`vesper.json` spell colours in the four-digit `#RGBA` form (`#0000`, `#FFFF`)
that VS Code accepts, which `src/ui/theme.zig` now parses next to `#RGB`,
`#RRGGBB` and `#RRGGBBAA`, and `one-light.json` writes
`"foreground": "inherit"` for a punctuation scope, which
`src/services/theme_vscode.zig` records as a rule that sets no colour - the scope
then keeps the colour of the scope around it, since `ui.theme.styleFor` composes
rules in document order and a rule that sets nothing replaces nothing. The
catalog's own tests load every file of the collection, so the next spelling the
reader does not know is a failing test rather than a row of the picker that
refuses to preview.
