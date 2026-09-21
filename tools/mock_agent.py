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


# How long the mock holds between the chunks of a streamed run. Long enough for
# a frame to be drawn while the run is still arriving, which is what the pulse
# fixture is looking for, and short enough that a gate run stays quick.
reasoning_pause = 0.25


# A 16x16 RGBA PNG: four 8x8 quadrants - red, green, blue, yellow - with a white
# diagonal across them. Small enough to write down, structured enough that a
# drawing of it is unmistakable in a screenshot, and real enough that a decoder
# has to decode it rather than being handed something that happens to parse.
SAMPLE_PNG_BASE64 = (
    "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAYUlEQVR42p3M0QkAIQyD4Q6WSW4SR3SIG8INPAQFkZpLG/jfwmd97gXcUB+ajRNDJIAhMnBDQoCHhIETSQE7kgZUxFBaZ621CrdfYJwYIgEMkYEbEgI8JAycSArYkTSwkA91yLusbERALAAAAABJRU5ErkJggg=="
)


class MockAgent:
    def __init__(self, name: str, fragment: int, delay: float, output: BinaryIO, require_auth: bool = False) -> None:
        self.name = name
        self.require_auth = require_auth
        self.auth_method = "mock-login"
        self.authenticated = False
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
                "authMethods": (
                    [{"id": self.auth_method, "name": "Mock login", "description": "The mock accepts its own method"}]
                    if self.require_auth
                    else []
                ),
            })
        elif method == "authenticate":
            if not self.initialized:
                self.error(request_id, -32600, "Initialize first")
                return
            if not isinstance(params.get("methodId"), str):
                self.error(request_id, -32602, "methodId is required")
                return
            if params["methodId"] != self.auth_method:
                self.error(request_id, -32602, "Unknown authentication method")
                return
            self.authenticated = True
            self.result(request_id, {})
        elif method == "session/new":
            if not self.initialized:
                self.error(request_id, -32600, "Initialize first")
                return
            cwd = params.get("cwd", "")
            if not isinstance(cwd, str) or not os.path.isabs(cwd) or not isinstance(params.get("mcpServers"), list):
                self.error(request_id, -32602, "Absolute cwd and an mcpServers array are required")
                return
            if self.require_auth and not self.authenticated:
                self.error(request_id, -32000, f"Authentication required: {self.auth_method}")
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
        exit, read the bounded output, then release ownership.

        The terminal is also embedded in a tool call while it is still running,
        which is what the protocol asks a client to draw: the call says which
        terminal it ran in and the client shows that terminal's output where the
        call is. The call is announced *before* the wait, so the screen has
        something in it by the time the turn ends, and the release comes after -
        a client that only draws a terminal it still owns is a client that blanks
        the output the moment the agent is done with it.
        """
        created = self.client_call(turn, "term", "terminal/create", {
            "sessionId": turn.session_id,
            "command": "sh",
            "args": ["-c", "echo seggs-terminal-ok"],
        })
        terminal_id = created.get("result", {}).get("terminalId")
        if not terminal_id:
            return "\nterminal-create-failed"
        self.update(turn.session_id, {
            "sessionUpdate": "tool_call",
            "toolCallId": "mock-term",
            "title": "Run in a terminal",
            "kind": "execute",
            "status": "in_progress",
            "rawInput": {"command": "echo seggs-terminal-ok"},
            "content": [{"type": "terminal", "terminalId": terminal_id}],
        })
        exit_reply = self.client_call(turn, "termexit", "terminal/wait_for_exit", {"sessionId": turn.session_id, "terminalId": terminal_id})
        exit_code = exit_reply.get("result", {}).get("exitCode")
        output_reply = self.client_call(turn, "termout", "terminal/output", {"sessionId": turn.session_id, "terminalId": terminal_id})
        output = output_reply.get("result", {}).get("output", "")
        self.update(turn.session_id, {"sessionUpdate": "tool_call_update", "toolCallId": "mock-term", "status": "completed"})
        self.client_call(turn, "termrel", "terminal/release", {"sessionId": turn.session_id, "terminalId": terminal_id})
        if exit_code == 0 and "seggs-terminal-ok" in output:
            return "\nterminal-ok"
        return f"\nterminal-failed:exit={exit_code}:output={output!r}"

    def tool_calls(self, turn: Turn) -> str:
        """The shapes a call chip has to draw: a read that finished, an edit
        carrying the diff it made, a command that failed, and a command still
        running. Four kinds, and the four states a chip colours."""
        session = turn.session_id
        self.update(session, {"sessionUpdate": "tool_call", "toolCallId": "mock-read", "title": "Read src/app.zig", "kind": "read", "status": "pending", "locations": [{"path": "src/app.zig"}]})
        self.update(session, {"sessionUpdate": "tool_call_update", "toolCallId": "mock-read", "status": "completed", "locations": [{"path": "src/app.zig"}]})
        # An edit is what a diff arrives on: the pair of texts and the path are
        # the whole of what the reader is shown, so the fixture sends them
        # rather than a file the editor would have to read itself.
        self.update(session, {
            "sessionUpdate": "tool_call",
            "toolCallId": "mock-edit",
            "title": "Edit src/ui/tool_call.zig",
            "kind": "edit",
            "status": "in_progress",
            "locations": [{"path": "src/ui/tool_call.zig"}],
            "content": [{
                "type": "diff",
                "path": "src/ui/tool_call.zig",
                "oldText": "const Allocator = std.mem.Allocator;\nconst Drawer = @import(\"../gpu/renderer.zig\").Renderer;\nconst Surface = @import(\"../gpu/surface.zig\").Surface;\n",
                "newText": "const Allocator = std.mem.Allocator;\nconst Drawer = @import(\"../gpu/renderer.zig\").Canvas;\nconst Surface = @import(\"../gpu/surface.zig\").Surface;\n",
            }, {
                # A patch the agent printed rather than a pair of sides. Only
                # this shape carries context lines: two sides written out as one
                # are a whole-block replacement, because context invented for an
                # excerpt the agent never sent would be read as the file. So this
                # part is the only one that exercises the highlighting of an
                # unchanged line.
                "type": "diff",
                "path": "src/ui/tool_call.zig",
                "diff": "--- a/src/ui/tool_call.zig\n+++ b/src/ui/tool_call.zig\n@@ -1,3 +1,3 @@\n const keep = 1;\n-const value = 10;\n+const value = 20;\n",
            }],
        })
        self.update(session, {"sessionUpdate": "tool_call_update", "toolCallId": "mock-edit", "status": "completed"})
        self.update(session, {"sessionUpdate": "tool_call", "toolCallId": "mock-fail", "title": "Run zig build verify", "kind": "execute", "status": "in_progress", "rawInput": {"command": "zig build verify"}, "content": [{"type": "content", "content": {"type": "text", "text": "error: the build failed"}}]})
        self.update(session, {"sessionUpdate": "tool_call_update", "toolCallId": "mock-fail", "status": "failed", "rawOutput": {"exitCode": 1, "output": "error: the build failed"}})
        self.update(session, {"sessionUpdate": "tool_call", "toolCallId": "mock-run", "title": "Run zig build test", "kind": "execute", "status": "in_progress", "rawInput": {"command": "zig build test"}})
        return "\ntool-calls=4"

    def complete(self, turn: Turn) -> None:
        # A harness that thinks, then works, then goes quiet: it takes a moment
        # before it has anything to say, then names the calls it is making, and
        # after that nothing arrives at all for the turn - which is what a
        # harness that has hung, or one that is waiting on something it will
        # never hear about, looks like from this side of the pipe. Nothing is
        # ever sent for the turn, so the silence that follows is the real thing.
        if turn.text.startswith("quiet"):
            turn.cancelled.wait(2.5)
            self.tool_calls(turn)
            return
        try:
            self.update(turn.session_id, {"sessionUpdate": "plan", "entries": [{"content": "Echo the prompt without workspace access", "priority": "medium", "status": "in_progress"}]})
            records = turn.text.startswith("records")
            if records:
                self.records_before(turn)
            permission = self.permission(turn) if turn.text.startswith("permission") else ""
            calls = self.tool_calls(turn) if turn.text.startswith("tools") else ""
            if turn.text.startswith("fsread "):
                fs_result = self.fs_read(turn)
            elif turn.text.startswith("fswrite "):
                fs_result = self.fs_write(turn)
            elif turn.text.startswith("terminal"):
                fs_result = self.terminal_run(turn)
            else:
                fs_result = ""
            if turn.text.startswith("math"):
                # Display mathematics in each form an agent writes it, so a run
                # exercises the parser and the typesetter together rather than
                # only whichever form the fixture happened to use.
                math = (
                    "\nHere is a fraction:\n\n"
                    "$$\\frac{1}{3}$$\n\n"
                    "One opened and closed on its own lines:\n\n"
                    "$$\n\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}\n$$\n\n"
                    "And a matrix:\n\n"
                    "$$\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}$$\n"
                )
            else:
                math = ""
            response = f"mock[{self.name}] {turn.text}\n{permission}{fs_result}{calls}{math}"
            for offset in range(0, len(response), 7):
                if turn.cancelled.is_set() or self.closed.is_set():
                    break
                self.update(turn.session_id, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": response[offset:offset + 7]}})
                turn.cancelled.wait(self.delay)
            # The summary arrives after the prose on purpose: it is the second
            # run of the turn, and a transcript that draws every run at the end
            # would put it in the same place as the reasoning rather than where
            # the session actually folded its context.
            if records:
                self.records_after(turn)
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

    def records_before(self, turn: Turn) -> None:
        """The updates a reader needs to see what a session is doing.

        One turn carries every kind the interface draws from a record: a stream
        of reasoning in many chunks (which has to arrive as one run, placed where
        it began), the user's own words, the usage of the turn, the mode, what
        the session is called, the commands it accepts, and a plan that replaces
        itself rather than appending. They are here because nothing else in the
        mock sends them, and a kind nothing sends is a kind no fixture can tell
        apart from one the client drops.
        """
        session = turn.session_id
        # The reasoning is sent slowly on purpose: a run that arrives in one
        # frame is never caught mid-arrival, and a client that draws reasoning
        # only after it has stopped is a client whose reader cannot tell thinking
        # from done. The pause is the fixture's, not the client's.
        for index, piece in enumerate(("A transcript has to show what ", "the agent thought, ", "not only what it called.")):
            if index != 0:
                turn.cancelled.wait(reasoning_pause)
            self.update(session, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": piece}})
        # A picture, and a real one: sixteen pixels square, four quadrants of
        # distinct colour with a white diagonal. The bytes matter - a two-byte
        # `aGk=` is valid base64 and not a PNG, so a client that decoded it would
        # fail, and a fixture that sent it would prove nothing about a picture
        # being drawn. These are the bytes `src/acp/image.zig` names as its own
        # sample, and the gate looks for their colours on screen.
        self.update(session, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "image", "data": SAMPLE_PNG_BASE64, "mimeType": "image/png"}})
        self.update(session, {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "show me the records"}})
        self.update(session, {"sessionUpdate": "usage_update", "used": 42000, "size": 200000, "cost": {"amount": 1.25, "currency": "USD"}})
        self.update(session, {"sessionUpdate": "current_mode_update", "currentModeId": "plan"})
        self.update(session, {"sessionUpdate": "session_info_update", "title": "Records fixture", "updatedAt": "2026-09-21T10:00:00Z"})
        self.update(session, {"sessionUpdate": "available_commands_update", "availableCommands": [
            {"name": "compact", "description": "Fold the context"},
            {"name": "research", "description": "Look something up", "input": {"hint": "what to look up"}},
        ]})
        self.update(session, {"sessionUpdate": "plan_update", "plan": {"type": "items", "planId": "mock-plan", "entries": [
            {"content": "capture the reasoning", "priority": "high", "status": "completed"},
            {"content": "draw it where it happened", "priority": "medium", "status": "in_progress"},
            {"content": "show what a turn cost", "priority": "low", "status": "pending"},
        ]}})

    def records_after(self, turn: Turn) -> None:
        """A compaction that streams its summary and then reports itself done."""
        session = turn.session_id
        for index, piece in enumerate(("Earlier: the transcript kept ", "three kinds of update ", "and dropped the rest.")):
            if index != 0:
                turn.cancelled.wait(reasoning_pause)
            self.update(session, {"sessionUpdate": "compaction_summary_chunk", "compactionId": "mock-compaction", "content": {"type": "text", "text": piece}})
        self.update(session, {"sessionUpdate": "compaction_update", "compactionId": "mock-compaction", "status": "completed"})

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
    parser.add_argument("--require-auth", action="store_true", help="Refuse a session until the client authenticates")
    args = parser.parse_args()
    if not 0 <= args.fragment <= 65536 or not 0 <= args.delay <= 1:
        parser.error("Invalid fragment size or delay")
    agent = MockAgent(args.name, args.fragment, args.delay, sys.stdout.buffer, args.require_auth)
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
