#!/usr/bin/env python3
"""Local ACP v1 fixture. This agent never reads or writes workspace files."""
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from dataclasses import dataclass, field
from typing import Any, BinaryIO

MAX_FRAME = 1024 * 1024


@dataclass
class Turn:
    request_id: int | str
    session_id: str
    text: str
    cancelled: threading.Event = field(default_factory=threading.Event)
    permission_ready: threading.Event = field(default_factory=threading.Event)
    permission_reply: dict[str, Any] | None = None


class MockAgent:
    def __init__(self, name: str, fragment: int, delay: float, output: BinaryIO) -> None:
        self.name = name
        self.fragment = fragment
        self.delay = delay
        self.output = output
        self.write_lock = threading.Lock()
        self.state_lock = threading.Lock()
        self.sessions: set[str] = set()
        self.turns: dict[str, Turn] = {}
        self.permissions: dict[str, Turn] = {}
        self.threads: list[threading.Thread] = []
        self.initialized = False
        self.closed = threading.Event()
        self.serial = 0

    def send(self, value: dict[str, Any]) -> None:
        packet = (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        with self.write_lock:
            if self.closed.is_set():
                return
            try:
                size = self.fragment or len(packet)
                for offset in range(0, len(packet), size):
                    self.output.write(packet[offset:offset + size])
                    self.output.flush()
            except (BrokenPipeError, OSError):
                self.closed.set()

    def result(self, request_id: Any, value: Any) -> None:
        self.send({"jsonrpc": "2.0", "id": request_id, "result": value})

    def error(self, request_id: Any, code: int, message: str) -> None:
        self.send({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})

    def update(self, session: str, value: dict[str, Any]) -> None:
        self.send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": value}})

    def dispatch(self, packet: Any) -> None:
        if not isinstance(packet, dict) or packet.get("jsonrpc") != "2.0":
            self.error(None, -32600, "Invalid JSON-RPC envelope")
            return
        request_id = packet.get("id")
        if "method" not in packet:
            with self.state_lock:
                turn = self.permissions.pop(str(request_id), None)
            if turn is not None:
                turn.permission_reply = packet
                turn.permission_ready.set()
            return
        method = packet["method"]
        params = packet.get("params", {})
        if not isinstance(method, str) or not isinstance(params, dict):
            self.error(request_id, -32602, "Invalid method or params")
            return
        if method == "initialize":
            if params.get("protocolVersion") != 1:
                self.error(request_id, -32602, "ACP protocolVersion must equal 1")
                return
            self.initialized = True
            self.result(request_id, {
                "protocolVersion": 1,
                "agentInfo": {"name": "seggs-mock", "title": self.name, "version": "0.1.0"},
                "agentCapabilities": {"loadSession": False, "promptCapabilities": {"image": False, "audio": False, "embeddedContext": False}},
                "authMethods": [],
            })
        elif method == "session/new":
            if not self.initialized:
                self.error(request_id, -32600, "Initialize first")
                return
            cwd = params.get("cwd", "")
            if not isinstance(cwd, str) or not os.path.isabs(cwd) or not isinstance(params.get("mcpServers"), list):
                self.error(request_id, -32602, "Absolute cwd and an mcpServers array are required")
                return
            self.serial += 1
            session = f"mock-{os.getpid()}-{self.serial}"
            self.sessions.add(session)
            self.result(request_id, {"sessionId": session})
        elif method == "session/prompt":
            session = params.get("sessionId")
            prompt = params.get("prompt")
            if not isinstance(session, str) or session not in self.sessions or not isinstance(prompt, list):
                self.error(request_id, -32602, "Invalid session or prompt")
                return
            if not all(isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str) for block in prompt):
                self.error(request_id, -32602, "This mock accepts text blocks only")
                return
            text = "\n".join(block["text"] for block in prompt)
            with self.state_lock:
                if session in self.turns:
                    self.error(request_id, -32600, "One active turn per session")
                    return
                turn = Turn(request_id, session, text)
                self.turns[session] = turn
            thread = threading.Thread(target=self.complete, args=(turn,), daemon=True)
            self.threads.append(thread)
            thread.start()
        elif method == "session/cancel":
            with self.state_lock:
                turn = self.turns.get(params.get("sessionId"))
            if turn is not None:
                turn.cancelled.set()
                turn.permission_ready.set()
        elif "id" in packet:
            self.error(request_id, -32601, "Method not supported by the mock")

    def permission(self, turn: Turn) -> str:
        call = {"toolCallId": "mock-tool", "title": "Mock permission: no file access", "kind": "read", "status": "pending"}
        self.update(turn.session_id, {"sessionUpdate": "tool_call", **call})
        permission_id = f"permission:{turn.session_id}:{turn.request_id}"
        with self.state_lock:
            self.permissions[permission_id] = turn
        self.send({"jsonrpc": "2.0", "id": permission_id, "method": "session/request_permission", "params": {
            "sessionId": turn.session_id,
            "toolCall": call,
            "options": [
                {"optionId": "once", "name": "Allow once", "kind": "allow_once"},
                {"optionId": "never", "name": "Reject once", "kind": "reject_once"},
            ],
        }})
        turn.permission_ready.wait(10)
        with self.state_lock:
            self.permissions.pop(permission_id, None)
        result = (turn.permission_reply or {}).get("result", {})
        outcome = result.get("outcome", {}) if isinstance(result, dict) else {}
        allowed = outcome.get("outcome") == "selected" and outcome.get("optionId") == "once" and not turn.cancelled.is_set()
        self.update(turn.session_id, {"sessionUpdate": "tool_call_update", "toolCallId": "mock-tool", "status": "completed" if allowed else "failed"})
        return "permission=allowed" if allowed else "permission=rejected"

    def complete(self, turn: Turn) -> None:
        try:
            self.update(turn.session_id, {"sessionUpdate": "plan", "entries": [{"content": "Echo the prompt without workspace access", "priority": "medium", "status": "in_progress"}]})
            permission = self.permission(turn) if turn.text.startswith("permission") else ""
            response = f"mock[{self.name}] {turn.text}\n{permission}"
            for offset in range(0, len(response), 7):
                if turn.cancelled.is_set() or self.closed.is_set():
                    break
                self.update(turn.session_id, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": response[offset:offset + 7]}})
                turn.cancelled.wait(self.delay)
            if turn.text.startswith("slow"):
                turn.cancelled.wait(2)
            stop = "cancelled" if turn.cancelled.is_set() else "end_turn"
            # Clear busy state before the completion becomes observable to a client.
            with self.state_lock:
                self.turns.pop(turn.session_id, None)
            self.result(turn.request_id, {"stopReason": stop})
        except Exception as exc:
            with self.state_lock:
                self.turns.pop(turn.session_id, None)
            self.error(turn.request_id, -32603, f"Mock failure: {type(exc).__name__}")

    def close(self) -> None:
        self.closed.set()
        with self.state_lock:
            for turn in self.turns.values():
                turn.cancelled.set()
                turn.permission_ready.set()
        for thread in self.threads:
            thread.join(timeout=1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default="local")
    parser.add_argument("--fragment", type=int, default=0, help="Maximum bytes per stdout write")
    parser.add_argument("--delay", type=float, default=0.01, help="Delay between text chunks")
    args = parser.parse_args()
    if not 0 <= args.fragment <= 65536 or not 0 <= args.delay <= 1:
        parser.error("Invalid fragment size or delay")
    agent = MockAgent(args.name, args.fragment, args.delay, sys.stdout.buffer)
    try:
        while not agent.closed.is_set():
            line = sys.stdin.buffer.readline(MAX_FRAME + 2)
            if not line:
                break
            if len(line) > MAX_FRAME + 1 or not line.endswith(b"\n"):
                agent.error(None, -32600, "Frame exceeds the limit or lacks a newline")
                return 2
            try:
                packet = json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                agent.error(None, -32700, "Invalid JSON")
                continue
            agent.dispatch(packet)
    finally:
        agent.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
