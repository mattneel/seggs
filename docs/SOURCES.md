# Upstream references

The scaffold used these primary references on September 19, 2026.
These links describe upstream interfaces, not proof of local compilation or live-agent tests.
The repository does not bundle third-party source or font files.

| Reference | Design use |
| --- | --- |
| [Zig 0.17.0 devlog](https://ziglang.org/devlog/2026/) | The reworked build system (maker/configurer split, package management in the build runner) and the new `@bitCast` semantics |
| [Official Zig download manifest](https://ziglang.org/download/index.json) | Exact release archive and SHA-256 lookup |
| [SDL 3.4.4 source](https://github.com/libsdl-org/SDL/tree/release-3.4.4) | Fixed native library baseline |
| [SDL_ttf 3.2.2 source](https://github.com/libsdl-org/SDL_ttf/tree/release-3.2.2) | Fixed glyph rasterization baseline |
| [zignal](https://github.com/arrufat/zignal) | TrueType parsing, glyph indices, kerning, and text layout for `src/gpu/shaper.zig` |
| [Ghostty](https://github.com/ghostty-org/ghostty) | libghostty-vt: terminal parsing, screen state, and the input encoders behind `src/services/vt.zig` |
| [Yoga](https://github.com/facebook/yoga) | Flexbox layout for interface an extension describes, behind `src/ui/yoga.h` |
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
