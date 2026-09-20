# Agent integrations

## Integration contract

Each preset supplies an executable and an argv array.
Seggs starts that command without shell expansion.
Each preset can supply a separate absolute working directory.
The application environment passes to the harness.

The harness must speak ACP v1 over newline-delimited stdio.
Stdout must contain protocol messages only.
Diagnostics belong on stderr.
Agents that require unsupported client capabilities need additional client implementation.

The project contains no model API client and no provider credentials.
A harness owns its model selection and authentication.
The scaffold does not implement `authenticate`, session resume, model selection, or mode selection through ACP.
The [source references](SOURCES.md) distinguish protocol and adapter interfaces.

## Oh-My-Pi

The upstream project exposes native ACP through `omp acp`.
Its separate RPC mode is not a substitute for ACP.
The first-class preset uses the native ACP command.

Install Oh-My-Pi through its documented package workflow.

```sh
bun install -g @oh-my-pi/pi-coding-agent
```

Complete the harness's authentication setup before the Seggs session.

The upstream command line and package installation can change.
The repository records the reference URL rather than claim a tested provider version.

## Codex

The Codex preset uses the ACP adapter package `@agentclientprotocol/codex-acp`.
Its executable is `codex-acp`.
The upstream adapter integrates with Codex rather than require an invented `codex --acp` flag.

Install the adapter.

```sh
npm install -g @agentclientprotocol/codex-acp
```

Complete the adapter's documented authentication setup outside Seggs.

The adapter owns the compatible Codex runtime boundary.
Seggs does not bundle or pin that runtime.
The older publisher namespace is not the default preset.

## Claude Code

The Claude preset uses `@agentclientprotocol/claude-agent-acp`.
Its executable is `claude-agent-acp`.
The upstream adapter uses the Claude Agent SDK.
It is not a native `claude --acp` invocation.

Install the adapter with a compatible Node.js runtime.

```sh
npm install -g @agentclientprotocol/claude-agent-acp
```

Complete the adapter's documented authentication setup outside Seggs.

The referenced package requires Node.js 22 or later.
The Oh-My-Pi and Claude Code live turns are verified; the Codex adapter remains untested.

## Explicit configuration

Copy the example config to a trusted location.

```sh
cp config/agents.example.json /absolute/path/to/trusted-agents.json
```

Replace the custom executable with the harness's actual ACP command.

Load that config explicitly.

```sh
zig build run -- --config /absolute/path/to/trusted-agents.json
```

Executable arguments retain their exact contents.
Relative script paths resolve from the agent's working directory, not from the config file's directory.
Only the built-in mock receives automatic script-path resolution.

## Parallel worktrees

**Do not treat concurrent sessions as file isolation.** Harnesses in one directory can change the same files.

Create separate worktrees before a parallel edit session.

```sh
git worktree add ../project-omp -b seggs/omp
git worktree add ../project-codex -b seggs/codex
git worktree add ../project-claude -b seggs/claude
```

Set each agent's `cwd` to its worktree's absolute path.

The worktree example at `config/parallel-worktrees.example.json` contains placeholders for those paths.
The explorer still shows the UI workspace, not the selected agent's separate worktree.
Seggs does not merge branches or arbitrate conflicts.

## Local fixture

`tools/mock_agent.py` needs no account or network access.
It supports text prompts and deterministic permission scenarios.
It emits plan, tool, and text updates.
Its fragment option divides stdout writes to exercise stream framing.

| Prompt prefix | Behavior |
| --- | --- |
| Ordinary text | Echo with the mock's lane name |
| `permission` | Request one-time permission without any file access |
| `slow` | Keep the turn active for cancellation |

The native smoke target uses three independent fixture processes.
The Python test suite tests the fixture, not the Zig implementation.

## Failure diagnosis

| Symptom | Likely boundary |
| --- | --- |
| `AgentSpawn` | Executable absent, invalid cwd, or platform process error |
| Initialization timeout | Wrong protocol, stdout diagnostics, or external authentication |
| Session creation error | Missing authentication, invalid cwd, or unsupported capability |
| Protocol limit or backpressure | Oversized frame or packet flood |
| Permission cancels on approval | Harness offered no `allow_once` option |
| Turn ignores cancellation | Harness did not complete the pending prompt within the deadline |

For protocol failures, inspect the harness's inherited stderr.
For authentication failures, use the harness's documented external setup.
