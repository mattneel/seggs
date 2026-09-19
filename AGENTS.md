# Repository instructions for coding agents

## Required boundaries

1. Use Zig 0.16.0.
2. Keep SDL declarations behind the `native` module.
3. Keep GPU calls on the application thread.
4. Keep editor and JSON state out of transport workers.
5. Preserve bounded queues and explicit buffer ownership.
6. Keep stderr separate from ACP stdout.
7. Keep permission approval explicit and request-local.
8. Never add automatic harness execution from workspace files.
9. Never advertise an unimplemented ACP capability.
10. Never add a font binary to the repository.

## Protocol work

Use newline-delimited JSON-RPC for ACP stdio.
Do not add LSP Content-Length headers to ACP messages.
Use separate framing for a future LSP transport.
Preserve string IDs in agent-to-client requests.
Reject unsupported client requests explicitly.

## Change validation

Run the core tests.

```sh
zig build test
```

Run the native transport test.

```sh
zig build integration
```

Compile the UI.

```sh
zig build check
```

Run the fixture and structure tests.

```sh
python3 -m unittest discover -s tests -v
python3 tools/check_repo.py
```

Run the formatter before a code review.

```sh
zig fmt build.zig src
```

## Reporting

Distinguish executed tests from proposed validation.
Describe unsupported capabilities in `docs/LIMITATIONS.md`.
Do not claim that Python fixture tests validate Zig code.
