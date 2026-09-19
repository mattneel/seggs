"""Subprocess tests for the fixture, not a substitute for native Zig tests."""
from __future__ import annotations

import contextlib
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import unittest
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]


class Peer:
    def __init__(self, name: str = "test", fragment: int = 3) -> None:
        self.process = subprocess.Popen(
            [sys.executable, str(ROOT / "tools/mock_agent.py"), "--name", name, "--fragment", str(fragment), "--delay", "0.001"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.messages: queue.Queue[Any] = queue.Queue()
        self.seen: list[dict[str, Any]] = []
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def read(self) -> None:
        assert self.process.stdout is not None
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        except Exception as exc:
            self.messages.put(exc)

    def __enter__(self) -> Peer:
        return self

    def __exit__(self, *_: Any) -> None:
        assert self.process.stdin is not None
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=3)
        self.thread.join(timeout=1)
        assert self.process.stdout is not None and self.process.stderr is not None
        errors = self.process.stderr.read().decode()
        self.process.stdout.close()
        self.process.stderr.close()
        if self.process.returncode not in (0, 2) or errors:
            raise AssertionError(f"Mock exit={self.process.returncode}: {errors}")

    def send(self, value: dict[str, Any]) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write((json.dumps(value, ensure_ascii=False) + "\n").encode())
        self.process.stdin.flush()

    def request(self, method: str, params: Any, request_id: int = 1) -> None:
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})

    def wait(self, predicate: Callable[[dict[str, Any]], bool], timeout: float = 5) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while True:
            packet = self.messages.get(timeout=max(0.001, deadline - time.monotonic()))
            if isinstance(packet, Exception):
                raise packet
            self.seen.append(packet)
            if predicate(packet):
                return packet
            if time.monotonic() >= deadline:
                raise TimeoutError("Expected packet absent")

    def result(self, request_id: int) -> dict[str, Any]:
        return self.wait(lambda p: p.get("id") == request_id and ("result" in p or "error" in p))

    def initialize(self) -> str:
        self.request("initialize", {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}})
        assert self.result(1)["result"]["protocolVersion"] == 1
        self.request("session/new", {"cwd": str(ROOT), "mcpServers": []}, 2)
        return self.result(2)["result"]["sessionId"]

    def prompt(self, session: str, text: str, request_id: int = 3) -> None:
        self.request("session/prompt", {"sessionId": session, "prompt": [{"type": "text", "text": text}]}, request_id)

    def text(self) -> str:
        return "".join(p.get("params", {}).get("update", {}).get("content", {}).get("text", "") for p in self.seen)


class MockTests(unittest.TestCase):
    def test_handshake_and_fragmented_unicode_stream(self) -> None:
        with Peer(fragment=1) as peer:
            session = peer.initialize()
            peer.prompt(session, 'Hello "Seggs"\nλ 🧠')
            self.assertEqual(peer.result(3)["result"]["stopReason"], "end_turn")
            self.assertIn('Hello "Seggs"\nλ 🧠', peer.text())

    def test_three_concurrent_independent_processes(self) -> None:
        with contextlib.ExitStack() as stack:
            peers = [stack.enter_context(Peer(name)) for name in ("alpha", "beta", "gamma")]
            sessions = [p.initialize() for p in peers]
            self.assertEqual(len(set(sessions)), 3)
            for index, peer in enumerate(peers):
                peer.prompt(sessions[index], f"token-{index}")
            for index, peer in enumerate(peers):
                self.assertEqual(peer.result(3)["result"]["stopReason"], "end_turn")
                self.assertIn(f"token-{index}", peer.text())
                for other in range(3):
                    if other != index:
                        self.assertNotIn(f"token-{other}", peer.text())

    def test_permission_reject_once(self) -> None:
        self.permission_case("never", "rejected")

    def test_permission_allow_once(self) -> None:
        self.permission_case("once", "allowed")

    def permission_case(self, option: str, expected: str) -> None:
        with Peer() as peer:
            session = peer.initialize()
            peer.prompt(session, "permission demonstration")
            request = peer.wait(lambda p: p.get("method") == "session/request_permission")
            self.assertIsInstance(request["id"], str)
            peer.send({"jsonrpc": "2.0", "id": request["id"], "result": {"outcome": {"outcome": "selected", "optionId": option}}})
            peer.result(3)
            self.assertIn(f"permission={expected}", peer.text())

    def test_cancel_and_reuse_session(self) -> None:
        with Peer() as peer:
            session = peer.initialize()
            peer.prompt(session, "slow first turn")
            peer.wait(lambda p: p.get("params", {}).get("update", {}).get("sessionUpdate") == "agent_message_chunk")
            peer.send({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": session}})
            self.assertEqual(peer.result(3)["result"]["stopReason"], "cancelled")
            peer.prompt(session, "second turn", 4)
            self.assertEqual(peer.result(4)["result"]["stopReason"], "end_turn")
            self.assertIn("second turn", peer.text())

    def test_cancel_pending_permission(self) -> None:
        with Peer() as peer:
            session = peer.initialize()
            peer.prompt(session, "permission cancel")
            peer.wait(lambda p: p.get("method") == "session/request_permission")
            peer.send({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": session}})
            self.assertEqual(peer.result(3)["result"]["stopReason"], "cancelled")

    def test_unknown_request(self) -> None:
        with Peer() as peer:
            peer.request("not/a/method", {}, 9)
            self.assertEqual(peer.result(9)["error"]["code"], -32601)

    def test_invalid_json_then_recover(self) -> None:
        with Peer() as peer:
            assert peer.process.stdin is not None
            peer.process.stdin.write(b"{broken}\n")
            peer.process.stdin.flush()
            self.assertEqual(peer.wait(lambda p: "error" in p)["error"]["code"], -32700)
            self.assertTrue(peer.initialize().startswith("mock-"))

    def test_session_requires_array_and_absolute_cwd(self) -> None:
        with Peer() as peer:
            peer.initialize()
            peer.request("session/new", {"cwd": ".", "mcpServers": []}, 5)
            self.assertEqual(peer.result(5)["error"]["code"], -32602)
            peer.request("session/new", {"cwd": str(ROOT), "mcpServers": ""}, 6)
            self.assertEqual(peer.result(6)["error"]["code"], -32602)

    def test_protocol_mismatch(self) -> None:
        with Peer() as peer:
            peer.request("initialize", {"protocolVersion": 99})
            self.assertEqual(peer.result(1)["error"]["code"], -32602)

    def test_frame_limit(self) -> None:
        with Peer(fragment=0) as peer:
            assert peer.process.stdin is not None
            peer.process.stdin.write(b"x" * (1024 * 1024 + 2))
            peer.process.stdin.flush()
            self.assertEqual(peer.wait(lambda p: "error" in p)["error"]["code"], -32600)


if __name__ == "__main__":
    unittest.main()
