#!/usr/bin/env python3
"""Local ACP v1 fixture. The agent itself never touches workspace files: it
asks the client to read, write, and run commands through the advertised
filesystem and terminal capabilities."""
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
    fs_ready: threading.Event = field(default_factory=threading.Event)
    client_reply: dict[str, Any] | None = None


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
        self.fs_requests: dict[str, Turn] = {}
        self.modes: dict[str, str] = {}
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
            with self.state_lock:
                fs_turn = self.fs_requests.pop(str(request_id), None)
            if fs_turn is not None:
                fs_turn.client_reply = packet
                fs_turn.fs_ready.set()
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
            self.result(request_id, {"sessionId": session, "configOptions": [{"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": "default", "options": [{"value": "default", "name": "Default"}, {"value": "plan", "name": "Plan"}]}]})
        elif method == "session/set_config_option":
            session = params.get("sessionId")
            if not isinstance(session, str) or session not in self.sessions:
                self.error(request_id, -32602, "Invalid session")
                return
            config_id = params.get("configId")
            value = params.get("value")
            if not isinstance(config_id, str) or not isinstance(value, str):
                self.error(request_id, -32602, "Invalid config")
                return
            with self.state_lock:
                self.modes[session] = value
            self.result(request_id, {"configOptions": [{"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": value, "options": [{"value": "default", "name": "Default"}, {"value": "plan", "name": "Plan"}]}]})
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

    def client_call(self, turn: Turn, prefix: str, method: str, params: dict[str, Any]) -> dict[str, Any]:
        """Send a client-bound request and wait for its reply."""
        request_id = f"{prefix}:{turn.session_id}:{turn.request_id}"
        turn.fs_ready.clear()
        turn.client_reply = None
        with self.state_lock:
            self.fs_requests[request_id] = turn
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        turn.fs_ready.wait(10)
        with self.state_lock:
            self.fs_requests.pop(request_id, None)
        return turn.client_reply or {}

    def fs_read(self, turn: Turn) -> str:
        path = turn.text[7:].strip()
        reply = self.client_call(turn, "fs", "fs/read_text_file", {"sessionId": turn.session_id, "path": path})
        if "error" in reply:
            return f"\nfs-error:{reply['error'].get('message', '')}"
        content = reply.get("result", {}).get("content", "")
        return "\nfs-read-ok" if "MockAgent" in content else "\nfs-read-empty"

    def fs_write(self, turn: Turn) -> str:
        spec = turn.text[8:].strip()
        if "|" not in spec:
            return "\nfs-write-invalid"
        path, content = spec.split("|", 1)
        reply = self.client_call(turn, "fsw", "fs/write_text_file", {"sessionId": turn.session_id, "path": path, "content": content})
        return "\nfs-write-error" if "error" in reply else "\nfs-write-ok"

    def terminal_run(self, turn: Turn) -> str:
        """Exercise the client terminal capability end to end: create, wait for
        exit, read the bounded output, then release ownership."""
        created = self.client_call(turn, "term", "terminal/create", {
            "sessionId": turn.session_id,
            "command": "sh",
            "args": ["-c", "echo seggs-terminal-ok"],
        })
        terminal_id = created.get("result", {}).get("terminalId")
        if not terminal_id:
            return "\nterminal-create-failed"
        exit_reply = self.client_call(turn, "termexit", "terminal/wait_for_exit", {"sessionId": turn.session_id, "terminalId": terminal_id})
        exit_code = exit_reply.get("result", {}).get("exitCode")
        output_reply = self.client_call(turn, "termout", "terminal/output", {"sessionId": turn.session_id, "terminalId": terminal_id})
        output = output_reply.get("result", {}).get("output", "")
        self.client_call(turn, "termrel", "terminal/release", {"sessionId": turn.session_id, "terminalId": terminal_id})
        if exit_code == 0 and "seggs-terminal-ok" in output:
            return "\nterminal-ok"
        return f"\nterminal-failed:exit={exit_code}:output={output!r}"

    def complete(self, turn: Turn) -> None:
        try:
            self.update(turn.session_id, {"sessionUpdate": "plan", "entries": [{"content": "Echo the prompt without workspace access", "priority": "medium", "status": "in_progress"}]})
            permission = self.permission(turn) if turn.text.startswith("permission") else ""
            if turn.text.startswith("fsread "):
                fs_result = self.fs_read(turn)
            elif turn.text.startswith("fswrite "):
                fs_result = self.fs_write(turn)
            elif turn.text.startswith("terminal"):
                fs_result = self.terminal_run(turn)
            else:
                fs_result = ""
            response = f"mock[{self.name}] {turn.text}\n{permission}{fs_result}"
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
            for turn in self.fs_requests.values():
                turn.fs_ready.set()
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
