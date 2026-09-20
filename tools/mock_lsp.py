#!/usr/bin/env python3
"""Minimal LSP server fixture: acknowledges initialize, publishes one
diagnostic after didOpen, and answers definition, references, and hover with
deterministic locations. Used by the native LSP test."""
import json
import sys


def read_frame():
    header = b""
    while b"\r\n\r\n" not in header:
        byte = sys.stdin.buffer.read(1)
        if not byte:
            return None
        header += byte
    content_length = 0
    for line in header.split(b"\r\n"):
        if line.startswith(b"Content-Length:"):
            content_length = int(line[len(b"Content-Length:"):].strip())
    body = sys.stdin.buffer.read(content_length)
    return json.loads(body)


def send(obj):
    body = json.dumps(obj).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode("utf-8") + body)
    sys.stdout.buffer.flush()


def location(uri, line, character):
    return {
        "uri": uri,
        "range": {
            "start": {"line": line, "character": character},
            "end": {"line": line, "character": character + 4},
        },
    }


document_uri = ""

while True:
    msg = read_frame()
    if msg is None:
        break
    method = msg.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"capabilities": {}}})
    elif method == "textDocument/didOpen":
        document_uri = msg["params"]["textDocument"]["uri"]
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {
            "uri": document_uri,
            "diagnostics": [{"range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 5}}, "message": "mock diagnostic", "severity": 1}],
        }})
    elif method == "textDocument/definition":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": location(document_uri, 0, 0)})
    elif method == "textDocument/references":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": [
            location(document_uri, 0, 0),
            location(document_uri, 2, 3),
        ]})
    elif method == "textDocument/hover":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {
            "contents": {"kind": "plaintext", "value": "mock hover"},
        }})
