#!/usr/bin/env python3
"""Exercise native observation delivery with local fake providers and MCP only."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAYLOAD = "visible voucher classification " + "x" * 18000 + ' actor_scope=unknown jurisdiction=unknown'


def mcp_fixture() -> None:
    for line in sys.stdin:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request["method"]
        if method == "initialize":
            result = {"protocolVersion": request["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": "fixture", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "echo", "description": "Return the local fixture source.", "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}, "annotations": {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True}}]}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": PAYLOAD}], "isError": False}
        else:
            result = {}
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


class ObservationTest(unittest.TestCase):
    binary = Path(__file__).resolve().parents[1] / "zig-out/bin/fx"
    observations_output: Path | None = None

    def exercise(self, *, enabled: bool, limit: int = 262144, tool: bool = True, capture: bool = True, call_count: int = 1, hooks: bool = False) -> tuple[list[dict], list[bytes]]:
        bodies: list[bytes] = []

        class Provider(BaseHTTPRequestHandler):
            def log_message(self, *_: object) -> None:
                pass

            def do_POST(self) -> None:
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                bodies.append(raw)
                first = len(bodies) == 1 and tool
                delta = {"tool_calls": [{"index": index, "id": f"fixture_call_{index + 1}", "type": "function", "function": {"name": "mcp_koi_test_echo", "arguments": "{}"}} for index in range(call_count)], "reasoning": "PRIVATE_REASONING_FIXTURE"} if first else {"content": "Scoped fixture answer."}
                events = [
                    {"id": "fixture", "model": "local-model", "choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
                    {"id": "fixture", "model": "local-model", "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls" if first else "stop"}]},
                    {"id": "fixture", "model": "local-model", "choices": [], "usage": {"prompt_tokens": 12, "completion_tokens": 3, "total_tokens": 15}},
                ]
                output = "".join("data: " + json.dumps(event) + "\n\n" for event in events) + "data: [DONE]\n\n"
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(output.encode())))
                self.end_headers()
                self.wfile.write(output.encode())

        with tempfile.TemporaryDirectory(prefix="fx-observations-") as directory:
            root = Path(directory)
            home, workspace = root / "home", root / "workspace"
            (home / ".fx").mkdir(parents=True)
            workspace.mkdir()
            server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            settings = {
                "provider": "local", "auto_upgrade": False, "session_titles": False,
                "permission": {"*": "deny", "mcp_koi_test_echo": "allow"},
                "providers": {"local": {"protocol": "openai-chat-completions", "base_url": f"http://127.0.0.1:{server.server_port}/v1", "auth": {"type": "none"}, "model_metadata": {"local-model": {"context_window": 262144, "max_output_tokens": 8192, "supports_tool_use": True}}}},
                "models": {"local": "local-model"},
            }
            (home / ".fx/settings.json").write_text(json.dumps(settings))
            environment = {"HOME": str(home), "PATH": os.defpath, "NO_COLOR": "1", "FX_AUTO_UPGRADE": "0", "FX_SOUND": "0", "FX_SESSIONS_V2": "1", "FX_DISABLE_KEYCHAIN": "1"}
            process = subprocess.Popen([str(self.binary.resolve()), "acp"], cwd=workspace, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            lines: queue.Queue[str] = queue.Queue()
            output: list[dict] = []

            def read_lines() -> None:
                assert process.stdout is not None
                for line in process.stdout:
                    lines.put(line)

            reader = threading.Thread(target=read_lines, daemon=True)
            reader.start()

            def request(identifier: int, method: str, params: dict) -> dict:
                assert process.stdin is not None
                process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}) + "\n")
                process.stdin.flush()
                while True:
                    message = json.loads(lines.get(timeout=30))
                    output.append(message)
                    if message.get("id") == identifier:
                        self.assertNotIn("error", message)
                        return message["result"]
                    self.assertFalse("id" in message, "Fixture must not prompt for permissions")

            try:
                initialize = {"protocolVersion": 1, "clientCapabilities": {}, "_meta": {"fx": {"terminal": False}}}
                if enabled:
                    initialize["_meta"]["fx"]["observations"] = {"version": 1, "capture_content": capture, "max_content_bytes": limit}
                initialized = request(1, "initialize", initialize)
                if enabled:
                    self.assertEqual(initialized["_meta"]["fx"]["observations"]["version"], 1)
                else:
                    self.assertNotIn("_meta", initialized)
                session_params = {"cwd": str(workspace), "mcpServers": [{"name": "koi_test", "command": sys.executable, "args": [str(Path(__file__).resolve()), "--mcp-fixture"], "env": []}] if tool else [], "systemPrompt": [{"type": "text", "text": "VISIBLE_CLIENT_INSTRUCTIONS"}]}
                if hooks:
                    session_params["_meta"] = {"fx": {"hooks": {"captureContent": False}}}
                session = request(2, "session/new", session_params)
                if hooks:
                    self.assertEqual(session["_meta"]["fx"]["hooksVersion"], 1)
                result = request(3, "session/prompt", {"sessionId": session["sessionId"], "prompt": [{"type": "text", "text": "Use the fixture source."}]})
                self.assertEqual(result["stopReason"], "end_turn")
                hook_events = [message["params"] for message in output if message.get("method") == "libfx/hook"]
                if hooks:
                    self.assertTrue({"turn.start", "turn.end", "model.start", "model.end"} <= {value["type"] for value in hook_events})
                    self.assertTrue(all(value["sessionId"] == session["sessionId"] for value in hook_events))
                else:
                    self.assertEqual(hook_events, [])
                assert process.stdin is not None
                process.stdin.close()
                self.assertEqual(process.wait(timeout=10), 0)
                assert process.stderr is not None
                self.assertEqual(process.stderr.read(), "")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                server.shutdown()
                server.server_close()
                worker.join(timeout=5)
                if process.stdin is not None and not process.stdin.closed:
                    process.stdin.close()
                for stream in (process.stdout, process.stderr):
                    if stream is not None:
                        stream.close()
            return [message["params"] for message in output if message.get("method") == "fx/observation"], bodies

    def test_effective_model_input_matches_local_provider_and_excludes_reasoning(self) -> None:
        observations, bodies = self.exercise(enabled=True)
        self.assertEqual(len(bodies), 2)
        self.assertEqual([value["sequence"] for value in observations], list(range(1, len(observations) + 1)))
        if self.observations_output is not None:
            self.observations_output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with self.observations_output.open("w") as destination:
                self.observations_output.chmod(0o600)
                json.dump(observations, destination)
        requests = [value for value in observations if value["event"]["kind"] == "model.request"]
        self.assertEqual(len(requests), 2)
        self.assertIn("mcp_koi_test_echo", requests[0]["event"]["data"]["available_tool_names"])
        self.assertNotIn("read_tool_result", requests[0]["event"]["data"]["available_tool_names"])
        projected_first = json.loads(requests[0]["event"]["data"]["request"]["content_json"])
        self.assertEqual(projected_first["tools"], json.loads(bodies[0])["tools"])
        for observed, body in zip(requests, bodies, strict=True):
            captured = observed["event"]["data"]["request"]
            self.assertEqual(captured["sha256"], hashlib.sha256(body).hexdigest())
            self.assertEqual(captured["byte_count"], len(body))
            self.assertEqual(captured["content_projection"], "visible_text_no_reasoning")
            self.assertEqual(captured["content_sha256"], hashlib.sha256(captured["content_json"].encode()).hexdigest())
        prepared = next(value["event"]["data"] for value in observations if value["event"]["kind"] == "tool.prepared")
        self.assertGreater(prepared["original"]["byte_count"], 16384)
        self.assertTrue(prepared["truncated"])
        visible = prepared["model_visible"]["content_text"]
        self.assertIn("<tool_result_preview", visible)
        self.assertIn("read_tool_result", visible)
        self.assertNotIn("actor_scope", visible)
        actual_tool = next(item["content"] for item in json.loads(bodies[1])["messages"] if item["role"] == "tool")
        self.assertEqual(visible, actual_tool)
        projected = json.loads(requests[1]["event"]["data"]["request"]["content_json"])
        self.assertEqual(next(item["content"] for item in projected["messages"] if item["role"] == "tool"), actual_tool)
        self.assertIn("PRIVATE_REASONING_FIXTURE", bodies[1].decode())
        self.assertNotIn("PRIVATE_REASONING_FIXTURE", json.dumps(observations))
        self.assertIn("VISIBLE_CLIENT_INSTRUCTIONS", requests[0]["event"]["data"]["request"]["content_json"])
        finished = [value["event"]["data"] for value in observations if value["event"]["kind"] == "model.finished"]
        self.assertEqual(finished[0]["tool_call_ids"], [prepared["tool_call_id"]])
        self.assertEqual(finished[1]["output_text"], "Scoped fixture answer.")

    def test_multiple_mcp_results_each_observe_the_effective_preview(self) -> None:
        observations, bodies = self.exercise(enabled=True, call_count=2)
        prepared = [value["event"]["data"] for value in observations if value["event"]["kind"] == "tool.prepared"]
        self.assertEqual(len(prepared), 2)
        self.assertEqual({value["tool_call_id"] for value in prepared}, {"fixture_call_1", "fixture_call_2"})
        visible = [message["content"] for message in json.loads(bodies[1])["messages"] if message["role"] == "tool"]
        self.assertEqual([value["model_visible"]["content_text"] for value in prepared], visible)

    def test_private_observations_coexist_with_native_session_hooks(self) -> None:
        observations, bodies = self.exercise(enabled=True, hooks=True)
        requests = [value["event"]["data"]["request"] for value in observations if value["event"]["kind"] == "model.request"]
        self.assertEqual([value["sha256"] for value in requests], [hashlib.sha256(body).hexdigest() for body in bodies])
        self.assertEqual(len(requests), 2)

    def test_native_session_hooks_do_not_enable_private_observations(self) -> None:
        observations, bodies = self.exercise(enabled=False, hooks=True, tool=False)
        self.assertEqual(observations, [])
        self.assertEqual(len(bodies), 1)

    def test_metadata_only_has_hashes_and_tool_names_without_content(self) -> None:
        observations, _ = self.exercise(enabled=True, capture=False)
        serialized = json.dumps(observations)
        self.assertNotIn("VISIBLE_CLIENT_INSTRUCTIONS", serialized)
        self.assertNotIn("Scoped fixture answer.", serialized)
        self.assertNotIn("visible voucher classification", serialized)
        self.assertIn("mcp_koi_test_echo", serialized)
        request = next(value["event"]["data"]["request"] for value in observations if value["event"]["kind"] == "model.request")
        self.assertIsNone(request["content_json"])
        self.assertEqual(len(request["sha256"]), 64)

    def test_no_observations_without_opt_in(self) -> None:
        observations, _ = self.exercise(enabled=False, tool=False)
        self.assertEqual(observations, [])

    def test_capture_bound_omits_whole_projection_with_digest(self) -> None:
        observations, _ = self.exercise(enabled=True, limit=1, tool=False)
        request = next(value["event"]["data"]["request"] for value in observations if value["event"]["kind"] == "model.request")
        self.assertTrue(request["omitted"])
        self.assertIsNone(request["content_json"])
        self.assertEqual(len(request["content_sha256"]), 64)


if __name__ == "__main__":
    if "--mcp-fixture" in sys.argv:
        mcp_fixture()
    else:
        if "--observations-output" in sys.argv:
            index = sys.argv.index("--observations-output")
            ObservationTest.observations_output = Path(sys.argv[index + 1]).resolve()
            del sys.argv[index:index + 2]
        unittest.main()
