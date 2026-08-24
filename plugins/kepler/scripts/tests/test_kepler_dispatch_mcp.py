from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "kepler_dispatch_mcp.py"
SPEC = importlib.util.spec_from_file_location("kepler_dispatch_mcp", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


FAKE_CODEX = r'''#!/usr/bin/env python3
import json
import sys

for line in sys.stdin:
    message = json.loads(line)
    request_id = message.get("id")
    method = message.get("method")
    if request_id is None:
        continue
    if method == "initialize":
        result = {"userAgent": "fake", "codexHome": "/tmp/fake"}
    elif method == "config/read":
        result = {"config": {
            "approval_policy": "on-request",
            "sandbox_mode": "danger-full-access",
        }}
    elif method == "permissionProfile/list":
        result = {"data": [
            {"id": ":workspace", "allowed": True},
            {"id": "named-profile", "allowed": True},
        ], "nextCursor": None}
    elif method == "thread/start":
        params = message["params"]
        result = {
            "thread": {"id": "thread-test"},
            "model": params["model"],
            "cwd": params["cwd"],
            "reasoningEffort": params["config"]["model_reasoning_effort"],
            "activePermissionProfile": (
                {"id": params["permissions"]} if "permissions" in params else None
            ),
            "approvalPolicy": "on-request",
            "sandbox": {"type": "dangerFullAccess"},
            "instructionSources": [params["cwd"] + "/AGENTS.md"],
        }
    elif method == "thread/name/set":
        result = {}
    else:
        print(json.dumps({"id": request_id, "error": {"message": method}}), flush=True)
        continue
    print(json.dumps({"id": request_id, "result": result}), flush=True)
'''


class KeplerDispatchMcpTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.project = self.root / "project"
        self.project.mkdir()
        self.fake_codex = self.root / "codex"
        self.fake_codex.write_text(textwrap.dedent(FAKE_CODEX), encoding="utf-8")
        self.fake_codex.chmod(self.fake_codex.stat().st_mode | stat.S_IXUSR)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def test_bootstrap_uses_effective_default_profile(self) -> None:
        result = MODULE.bootstrap_worker_task(
            cwd=str(self.project),
            title="Worker task",
            model="gpt-5.6-terra",
            thinking="high",
            codex_executable=str(self.fake_codex),
        )
        self.assertEqual("thread-test", result["threadId"])
        self.assertEqual("global-config", result["configurationMode"])
        self.assertIsNone(result["permissionProfile"])
        self.assertIsNone(result["activePermissionProfile"])
        self.assertEqual("on-request", result["approvalPolicy"])
        self.assertEqual("danger-full-access", result["sandboxMode"])
        self.assertEqual("dangerFullAccess", result["sandbox"]["type"])
        self.assertEqual("gpt-5.6-terra", result["model"])
        self.assertEqual("high", result["thinking"])
        self.assertTrue(result["empty"])

    def test_rejects_unknown_or_disallowed_profile(self) -> None:
        with self.assertRaisesRegex(MODULE.DispatchError, "unavailable or disallowed"):
            MODULE.bootstrap_worker_task(
                cwd=str(self.project),
                title="Worker task",
                model="gpt-5.6-terra",
                thinking="high",
                permission_profile="missing",
                codex_executable=str(self.fake_codex),
            )

    def test_planner_bootstrap_is_hard_bound_and_preserves_config(self) -> None:
        result = MODULE.bootstrap_planner_task(
            cwd=str(self.project),
            title="Sol planning task",
            current_model="gpt-5.6-terra",
            current_thinking="high",
            codex_executable=str(self.fake_codex),
        )
        self.assertEqual("kepler.planner-task-bootstrap/v1", result["schemaVersion"])
        self.assertEqual("created-separate-task", result["action"])
        self.assertTrue(result["created"])
        self.assertEqual("sol", result["role"])
        self.assertEqual("gpt-5.6-sol", result["model"])
        self.assertEqual("high", result["thinking"])
        self.assertEqual("global-config", result["configurationMode"])
        self.assertTrue(result["empty"])

    def test_planner_reuses_current_sol_high_task(self) -> None:
        result = MODULE.bootstrap_planner_task(
            cwd=str(self.project),
            title="Review plan",
            current_model="gpt-5.6-sol",
            current_thinking="high",
            codex_executable=str(self.root / "missing-codex"),
        )
        self.assertEqual("kepler.planner-task-reuse/v1", result["schemaVersion"])
        self.assertEqual("reuse-current-task", result["action"])
        self.assertFalse(result["created"])
        self.assertNotIn("threadId", result)
        self.assertEqual("gpt-5.6-sol", result["model"])
        self.assertEqual("high", result["thinking"])

    def test_explicit_request_can_create_separate_sol_high_task(self) -> None:
        result = MODULE.bootstrap_planner_task(
            cwd=str(self.project),
            title="Separate review plan",
            current_model="gpt-5.6-sol",
            current_thinking="high",
            separate_task_requested=True,
            codex_executable=str(self.fake_codex),
        )
        self.assertEqual("kepler.planner-task-bootstrap/v1", result["schemaVersion"])
        self.assertEqual("created-separate-task", result["action"])
        self.assertTrue(result["created"])
        self.assertEqual("thread-test", result["threadId"])

    def test_tool_schema_cannot_send_prompt_or_select_environment(self) -> None:
        for tool in MODULE.TOOLS:
            properties = tool["inputSchema"]["properties"]
            self.assertNotIn("prompt", properties)
            self.assertNotIn("environment", properties)
            self.assertFalse(tool["inputSchema"]["additionalProperties"])
        planner = MODULE.PLANNER_TOOL["inputSchema"]["properties"]
        self.assertNotIn("model", planner)
        self.assertNotIn("thinking", planner)
        self.assertIn("current_model", planner)
        self.assertIn("current_thinking", planner)
        self.assertIn("separate_task_requested", planner)
        self.assertIn(
            "current_model", MODULE.PLANNER_TOOL["inputSchema"]["required"]
        )
        self.assertIn(
            "current_thinking", MODULE.PLANNER_TOOL["inputSchema"]["required"]
        )

    def test_stdio_planner_call_reuses_current_sol_high_task(self) -> None:
        response = MODULE._handle_request(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {
                    "name": "bootstrap_planner_task",
                    "arguments": {
                        "cwd": str(self.project),
                        "title": "Review plan",
                        "current_model": "gpt-5.6-sol",
                        "current_thinking": "high",
                    },
                },
            }
        )
        assert response is not None
        receipt = response["result"]["structuredContent"]
        self.assertEqual("kepler.planner-task-reuse/v1", receipt["schemaVersion"])
        self.assertEqual("reuse-current-task", receipt["action"])
        self.assertFalse(receipt["created"])
        self.assertNotIn("threadId", receipt)

    def test_stdio_tool_call_returns_permission_receipt(self) -> None:
        environment = os.environ.copy()
        environment["KEPLER_CODEX_CLI_PATH"] = str(self.fake_codex)
        process = subprocess.Popen(
            [sys.executable, str(SCRIPT)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        assert process.stdin is not None and process.stdout is not None
        requests = [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": "2025-06-18"},
            },
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {
                    "name": "bootstrap_worker_task",
                    "arguments": {
                        "cwd": str(self.project),
                        "title": "Worker task",
                        "model": "gpt-5.6-terra",
                        "thinking": "high",
                    },
                },
            },
        ]
        for request in requests:
            process.stdin.write(json.dumps(request) + "\n")
        process.stdin.close()
        responses = [json.loads(line) for line in process.stdout]
        stderr = process.stderr.read() if process.stderr is not None else ""
        self.assertEqual(0, process.wait(timeout=5), stderr)
        process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()
        receipt = responses[1]["result"]["structuredContent"]
        self.assertEqual("kepler.worker-task-bootstrap/v1", receipt["schemaVersion"])
        self.assertEqual("global-config", receipt["configurationMode"])
        self.assertIsNone(receipt["permissionProfile"])


if __name__ == "__main__":
    unittest.main()
