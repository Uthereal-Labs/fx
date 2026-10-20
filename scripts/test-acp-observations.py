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

ROOT_TRACEPARENT = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"

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
            if "--trace-output" in sys.argv:
                path = Path(sys.argv[sys.argv.index("--trace-output") + 1])
                with path.open("a") as destination:
                    destination.write(json.dumps(request) + "\n")
            result = {"content": [{"type": "text", "text": PAYLOAD}], "isError": "--fail-tool" in sys.argv}
        else:
            result = {}
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


class ObservationTest(unittest.TestCase):
    binary = Path(__file__).resolve().parents[1] / "zig-out/bin/fx"
    observations_output: Path | None = None
    observations_v2_output: Path | None = None

    def exercise(self, *, enabled: bool, limit: int = 262144, tool: bool = True, capture: bool = True, call_count: int = 1, hooks: bool = False, version: int = 1, engine: str = "v1", parent: str = ROOT_TRACEPARENT, tool_failure: bool = False) -> tuple[list[dict], list[bytes]]:
        bodies: list[bytes] = []
        provider_headers: list[dict[str, str]] = []

        class Provider(BaseHTTPRequestHandler):
            def log_message(self, *_: object) -> None:
                pass

            def do_POST(self) -> None:
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                bodies.append(raw)
                provider_headers.append(dict(self.headers.items()))
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
            trace_output = root / "mcp-requests.jsonl"
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
            environment["FX_MCP_ENGINE"] = engine
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
                    initialize["_meta"]["fx"]["observations"] = {"version": version, "capture_content": capture, "max_content_bytes": limit, **({"traceparent": parent, "tracestate": "vendor=value"} if version == 2 else {})}
                initialized = request(1, "initialize", initialize)
                if enabled and version in (1, 2) and parent == ROOT_TRACEPARENT:
                    self.assertEqual(initialized["_meta"]["fx"]["observations"]["version"], version)
                else:
                    self.assertNotIn("_meta", initialized)
                session_params = {"cwd": str(workspace), "mcpServers": [{"name": "koi_test", "command": sys.executable, "args": [str(Path(__file__).resolve()), "--mcp-fixture", "--trace-output", str(trace_output), *(["--fail-tool"] if tool_failure else [])], "env": []}] if tool else [], "systemPrompt": [{"type": "text", "text": "VISIBLE_CLIENT_INSTRUCTIONS"}]}
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
            self.provider_headers = [{key.lower(): value for key, value in headers.items()} for headers in provider_headers]
            self.mcp_requests = [json.loads(line) for line in trace_output.read_text().splitlines()] if trace_output.exists() else []
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

    def test_v2_exact_native_tool_and_model_parents_reach_both_mcp_engines(self) -> None:
        for engine in ("v1", "v2"):
            with self.subTest(engine=engine):
                observations, bodies = self.exercise(enabled=True, version=2, engine=engine, call_count=2, hooks=True)
                models = [value for value in observations if value["event"]["kind"] == "model.request"]
                model_ends = [value for value in observations if value["event"]["kind"] == "model.finished"]
                tools = [value for value in observations if value["event"]["kind"] == "tool.started"]
                tool_ends = [value for value in observations if value["event"]["kind"] == "tool.finished"]
                projections = [value for value in observations if value["event"]["kind"] == "tool.prepared"]
                self.assertEqual((len(models), len(model_ends), len(tools), len(tool_ends), len(projections)), (2, 2, 2, 2, 2))
                self.assertEqual(len(self.mcp_requests), 2)
                self.assertEqual(len({value["trace"]["span_id"] for value in models + tools}), 4)
                self.assertEqual([value["sequence"] for value in observations], list(range(1, len(observations) + 1)))
                for value in models + tools:
                    self.assertEqual(value["version"], 2)
                    self.assertEqual(value["trace"]["trace_id"], ROOT_TRACEPARENT[3:35])
                    self.assertEqual(value["trace"]["parent_span_id"], ROOT_TRACEPARENT[36:52])
                for start, end, headers, body in zip(models, model_ends, self.provider_headers, bodies, strict=True):
                    self.assertEqual(start["trace"], end["trace"])
                    self.assertEqual(headers["traceparent"], f"00-{start['trace']['trace_id']}-{start['trace']['span_id']}-01")
                    self.assertEqual(headers["tracestate"], "vendor=value")
                    self.assertEqual(start["event"]["data"]["request"]["sha256"], hashlib.sha256(body).hexdigest())
                for start, end, projection, remote in zip(tools, tool_ends, projections, self.mcp_requests, strict=True):
                    self.assertEqual(start["trace"], end["trace"])
                    self.assertEqual(start["trace"], projection["trace"])
                    self.assertLess(start["sequence"], projection["sequence"])
                    self.assertLess(projection["sequence"], end["sequence"])
                    self.assertEqual(start["event"]["data"]["tool_call_id"], end["event"]["data"]["tool_call_id"])
                    self.assertEqual(remote["params"]["_meta"]["traceparent"], f"00-{start['trace']['trace_id']}-{start['trace']['span_id']}-01")
                    self.assertEqual(remote["params"]["_meta"]["tracestate"], "vendor=value")
                self.assertNotIn("PRIVATE_REASONING_FIXTURE", json.dumps(observations))
                if engine == "v1" and self.observations_v2_output is not None:
                    self.observations_v2_output.write_text(json.dumps(observations))

    def test_v2_failed_tool_finishes_after_projection_and_preserves_its_result(self) -> None:
        observations, _ = self.exercise(enabled=True, version=2, tool_failure=True)
        start = next(value for value in observations if value["event"]["kind"] == "tool.started")
        end = next(value for value in observations if value["event"]["kind"] == "tool.finished")
        prepared = next(value for value in observations if value["event"]["kind"] == "tool.prepared")
        self.assertEqual(start["trace"], end["trace"])
        self.assertEqual(end["event"]["data"]["outcome"], "failed")
        self.assertIn("visible voucher classification", end["event"]["data"]["output_text"])
        self.assertLess(prepared["sequence"], end["sequence"])

    def test_v2_tool_content_limit_omits_complete_fields_with_digests(self) -> None:
        observations, _ = self.exercise(enabled=True, version=2, limit=1)
        start = next(value["event"]["data"] for value in observations if value["event"]["kind"] == "tool.started")
        end = next(value["event"]["data"] for value in observations if value["event"]["kind"] == "tool.finished")
        self.assertIsNone(start["arguments_json"])
        self.assertTrue(start["arguments_omitted"])
        self.assertEqual(start["arguments_sha256"], hashlib.sha256(b"{}").hexdigest())
        self.assertEqual(start["arguments_byte_count"], 2)
        self.assertIsNone(end["output_text"])
        self.assertTrue(end["output_omitted"])
        self.assertGreater(end["output_byte_count"], 1)
        self.assertEqual(len(end["output_sha256"]), 64)

    def test_v2_metadata_only_keeps_native_tool_identities_without_content(self) -> None:
        observations, _ = self.exercise(enabled=True, version=2, capture=False)
        self.assertTrue(any(value["event"]["kind"] == "tool.finished" for value in observations))
        for value in observations:
            data = value["event"]["data"]
            if value["event"]["kind"] == "tool.started":
                self.assertIsNone(data["arguments_json"])
                self.assertTrue(data["arguments_omitted"])
            elif value["event"]["kind"] == "tool.finished":
                self.assertIsNone(data["output_text"])
                self.assertTrue(data["output_omitted"])
        self.assertNotIn("visible voucher classification", json.dumps(observations))

    def test_unsupported_or_invalid_trace_negotiation_does_not_change_execution(self) -> None:
        for version, parent in ((99, ROOT_TRACEPARENT), (2, "malformed")):
            observations, bodies = self.exercise(enabled=True, version=version, parent=parent, tool=False)
            self.assertEqual(observations, [])
            self.assertEqual(len(bodies), 1)
            self.assertNotIn("traceparent", self.provider_headers[0])

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
        if "--observations-v2-output" in sys.argv:
            index = sys.argv.index("--observations-v2-output")
            ObservationTest.observations_v2_output = Path(sys.argv[index + 1]).resolve()
            del sys.argv[index:index + 2]
        unittest.main()
