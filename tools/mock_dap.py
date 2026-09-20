#!/usr/bin/env python3
"""Minimal DAP adapter fixture: responds to every request and emits one
stopped event after configurationDone. Deterministic for tests."""
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


def body_for(command):
    if command == "stackTrace":
        return {"stackFrames": [{"id": 1, "name": "main", "line": 7, "column": 1}]}
    if command == "scopes":
        return {"scopes": [{"name": "Locals", "variablesReference": 100}]}
    if command == "variables":
        return {"variables": [{"name": "count", "value": "3"}, {"name": "label", "value": "\"seggs\""}]}
    return {}


seq = 0
while True:
    msg = read_frame()
    if msg is None:
        break
    if msg.get("type") == "request":
        seq += 1
        send({"seq": seq, "type": "response", "request_seq": msg["seq"], "success": True, "command": msg["command"], "body": body_for(msg["command"])})
        if msg.get("command") == "configurationDone":
            seq += 1
            send({"seq": seq, "type": "event", "event": "stopped", "body": {"reason": "breakpoint", "threadId": 1}})
        elif msg.get("command") in ("continue", "next", "stepIn", "stepOut"):
            seq += 1
            send({"seq": seq, "type": "event", "event": "continued", "body": {"threadId": 1}})
            seq += 1
            send({"seq": seq, "type": "event", "event": "stopped", "body": {"reason": "breakpoint", "threadId": 1}})
