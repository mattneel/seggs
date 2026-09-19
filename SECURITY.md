# Security model

## Local trust

Seggs is an unsandboxed local development application.
A harness process inherits the application's environment and the user's operating-system authority.
It can access files outside the UI workspace when the operating system permits that access.
Separate ACP lanes do not create security boundaries.

## Configuration

**Do not load an untrusted agent configuration.** The config selects executable programs and their arguments.

The app loads a config only through an explicit `--config` argument.
It does not discover executable settings in an opened repository.
The default presets do not start automatically.
An argv array does not use shell expansion unless it explicitly invokes a shell.

## Permissions

**Inspect the full tool request before approval.** A short title alone does not establish the operation's effects.

The client exposes explicit one-time decisions.
It never replaces `allow_once` with `allow_always`.
Unsupported or excess permission requests do not receive automatic approval.
The client does not restrict tool calls that bypass ACP permission requests.

## Files

**Use a disposable worktree during scaffold development.** The save path does not preserve all metadata or provide crash durability.

The baseline comparison reduces accidental overwrites but does not lock out concurrent agent changes.
The implementation does not enforce a workspace-only filesystem boundary.
It does not block symlink traversal during workspace enumeration.
Depth and count limits bound that enumeration.

## Protocol inputs

The transport limits frame size, queue bytes, and packet count.
The UI limits work per lane per frame.
Transcripts remain bounded in memory.
A parse error or transport limit fails the affected lane.

Unknown client methods receive `-32601`.
The client advertises filesystem and terminal support as false.
Those declarations describe ACP services, not operating-system restrictions.

## Credentials and transcripts

The repository contains no credentials.
The app does not intentionally persist transcripts or authentication data.
Harnesses retain their own storage and telemetry behavior.
Inherited stderr can contain sensitive diagnostics in the parent terminal.

## Issue reports

Remove credentials and private source text before a public report.
Include a minimized mock transcript when possible.
The scaffold does not define a private vulnerability-report address.
