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
| [zignal](https://github.com/arrufat/zignal) | TrueType parsing, glyph indices, kerning, and text layout for `src/gpu/shaper.zig` |
