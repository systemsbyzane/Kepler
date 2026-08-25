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
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "kepler_dispatch_mcp.py"
PROJECT_ID = "project-a"
SPEC = importlib.util.spec_from_file_location("kepler_dispatch_mcp", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


FAKE_CODEX = r'''#!/usr/bin/env python3
import json
import os
import sys

created_project = None

def thread_turns():
    marker = os.environ.get("FAKE_PROMPT_MARKER")
    prompt = None
    if marker and os.path.exists(marker):
        with open(marker, encoding="utf-8") as handle:
            prompt = handle.read()
    if prompt is None and os.environ.get("FAKE_THREAD_PROMPT"):
        prompt = os.environ["FAKE_THREAD_PROMPT"]
    if prompt is None and os.environ.get("FAKE_RESUME_NONEMPTY"):
        prompt = "existing prompt"
    if prompt is None:
        return []
    items = [{"id": "user-1", "type": "userMessage", "clientId": None, "content": [{"type": "text", "text": prompt}]}]
    result = os.environ.get("FAKE_RESULT_TEXT")
    if result is not None:
        items.append({"id": "agent-1", "type": "agentMessage", "phase": os.environ.get("FAKE_RESULT_PHASE", "final_answer"), "text": result})
    return [{"id": "turn-1", "status": os.environ.get("FAKE_TURN_STATUS", "inProgress"), "items": items}]

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
    elif method == "project/list":
        projects = json.loads(os.environ.get("FAKE_PROJECTS", "[]"))
        if created_project is not None and not projects:
            projects = [created_project]
        result = {"data": projects, "nextCursor": None}
    elif method == "project/create":
        params = message["params"]
        created_project = {
            "id": "cli-project-test",
            "name": params["name"],
            "roots": params["roots"],
            "metadata": params.get("metadata", {}),
            "createdAt": 1,
            "updatedAt": 1,
            "position": 0,
        }
        result = {"project": created_project}
    elif method == "project/read":
        projects = json.loads(os.environ.get("FAKE_PROJECTS", "[]"))
        project = created_project
        if project is None:
            project = next((entry for entry in projects if entry["id"] == message["params"]["projectId"]), None)
        result = {"project": project}
    elif method == "thread/start":
        params = message["params"]
        result = {
            "thread": {
                "id": "thread-test",
                "projectId": os.environ.get(
                    "FAKE_START_PROJECT_ID",
                    params.get(
                        "projectId", os.environ.get("FAKE_DISPATCHER_PROJECT_ID")
                    ),
                ),
            },
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
    elif method == "thread/resume":
        params = message["params"]
        active_profile = os.environ.get("FAKE_RESUME_PROFILE")
        if active_profile is None:
            active_profile = params.get("permissions")
        sandbox_mode = params.get("sandbox", "danger-full-access")
        sandbox_receipt = {
            "danger-full-access": "dangerFullAccess",
            "workspace-write": "workspaceWrite",
            "read-only": "readOnly",
        }[sandbox_mode]
        result = {
            "thread": {
                "id": params["threadId"],
                "projectId": os.environ.get("FAKE_RESUME_PROJECT_ID", "project-a"),
                "turns": ["existing-turn"] if os.environ.get("FAKE_RESUME_NONEMPTY") else [],
                "status": {"type": "active" if os.environ.get("FAKE_RESUME_ACTIVE") else "idle"},
            },
            "model": os.environ.get("FAKE_RESUME_MODEL", params.get("model", "gpt-5.6-sol")),
            "cwd": params.get("cwd", os.environ["FAKE_PROJECT_CWD"]),
            "reasoningEffort": os.environ.get(
                "FAKE_RESUME_THINKING",
                params.get("config", {}).get("model_reasoning_effort"),
            ),
            "activePermissionProfile": (
                {"id": active_profile} if active_profile else None
            ),
            "approvalPolicy": os.environ.get(
                "FAKE_RESUME_APPROVAL", params.get("approvalPolicy", "on-request")
            ),
            "sandbox": {
                "type": os.environ.get(
                    "FAKE_RESUME_SANDBOX", sandbox_receipt
                )
            },
        }
    elif method == "thread/read":
        result = {"thread": {
            "id": message["params"]["threadId"],
            "projectId": os.environ.get("FAKE_RESUME_PROJECT_ID", "project-a"),
            "cwd": os.environ["FAKE_PROJECT_CWD"],
            "turns": thread_turns() if message["params"].get("includeTurns") else [],
            "status": {"type": "active" if os.environ.get("FAKE_RESUME_ACTIVE") else "idle"},
        }}
    elif method == "thread/name/set":
        result = {}
    elif method == "thread/archive":
        if os.environ.get("FAKE_CODEX_LOG"):
            with open(os.environ["FAKE_CODEX_LOG"], "a", encoding="utf-8") as handle:
                handle.write("archive " + message["params"]["threadId"] + "\n")
        result = {}
    else:
        print(json.dumps({"id": request_id, "error": {"message": method}}), flush=True)
        continue
    print(json.dumps({"id": request_id, "result": result}), flush=True)
'''


FAKE_HERDR = r'''#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
log = os.environ.get("FAKE_HERDR_LOG")
if log:
    with open(log, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(args) + "\n")

def emit(result):
    print(json.dumps({"id": "fake", "result": result}))

cwd = os.environ["FAKE_PROJECT_CWD"]
name = os.environ.get("FAKE_HERDR_AGENT_NAME", "worker-agent")
session = os.environ.get("FAKE_HERDR_SESSION", "thread-test")
if args == ["agent", "list"]:
    agents = [{"name": name}] if os.environ.get("FAKE_HERDR_DUPLICATE") else []
    emit({"type": "agent_list", "agents": agents})
elif args == ["api", "schema", "--json"]:
    print(json.dumps({"protocol": int(os.environ.get("FAKE_HERDR_PROTOCOL", "19")), "schemas": {"success_response": {}}}))
elif args == ["status", "server", "--json"]:
    print(json.dumps({"version": "0.8.0", "protocol": int(os.environ.get("FAKE_HERDR_PROTOCOL", "19"))}))
elif args[:3] == ["pane", "current", "--current"]:
    emit({"type": "pane_current", "pane": {"workspace_id": "w0", "tab_id": "w0:t0", "pane_id": "w0:p0", "agent": "codex"}})
elif args[:2] == ["tab", "create"]:
    if os.environ.get("FAKE_HERDR_CREATE_FAIL"):
        sys.exit(1)
    emit({"type": "tab_created", "tab": {"workspace_id": "w0", "tab_id": "w0:t1"}, "root_pane": {"workspace_id": "w0", "tab_id": "w0:t1", "pane_id": "w0:p1", "cwd": os.environ.get("FAKE_HERDR_CWD", cwd)}})
elif args[:2] == ["agent", "start"]:
    if os.environ.get("FAKE_HERDR_START_FAIL"):
        sys.exit(1)
    separator = args.index("--")
    emit({"type": "agent_started", "agent": {"terminal_id": "term1"}, "argv": ["codex", *args[separator + 1:]]})
elif args[:2] == ["agent", "get"]:
    emit({"type": "agent_info", "agent": {"workspace_id": "w0", "tab_id": "w0:t1", "pane_id": "w0:p1", "terminal_id": "term1", "name": name, "agent": os.environ.get("FAKE_HERDR_KIND", "codex"), "cwd": os.environ.get("FAKE_HERDR_CWD", cwd), "agent_session": {"value": session}, "agent_status": os.environ.get("FAKE_HERDR_STATUS", "idle")}})
elif args[:2] == ["agent", "prompt"]:
    marker = os.environ.get("FAKE_PROMPT_MARKER")
    if marker:
        with open(marker, "w", encoding="utf-8") as handle:
            handle.write(args[3])
    emit({"type": "agent_prompted", "agent": {"name": name}})
elif args[:2] == ["workspace", "close"]:
    emit({"type": "ok"})
elif args[:2] == ["tab", "close"]:
    emit({"type": "ok"})
else:
    sys.exit(2)
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
        self.fake_herdr = self.root / "herdr"
        self.fake_herdr.write_text(textwrap.dedent(FAKE_HERDR), encoding="utf-8")
        self.fake_herdr.chmod(self.fake_herdr.stat().st_mode | stat.S_IXUSR)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def test_bootstrap_uses_effective_default_profile(self) -> None:
        result = MODULE.bootstrap_worker_task(
            cwd=str(self.project),
            expected_runtime_project_id=PROJECT_ID,
            title="Worker task",
            model="gpt-5.6-terra",
            thinking="high",
            codex_executable=str(self.fake_codex),
        )
        self.assertEqual("thread-test", result["threadId"])
        self.assertEqual(PROJECT_ID, result["expectedRuntimeProjectId"])
        self.assertEqual(PROJECT_ID, result["actualRuntimeProjectId"])
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
                expected_runtime_project_id=PROJECT_ID,
                title="Worker task",
                model="gpt-5.6-terra",
                thinking="high",
                permission_profile="missing",
                codex_executable=str(self.fake_codex),
            )

    def test_verify_worker_requires_exact_effective_configuration_before_prompt(self) -> None:
        with mock.patch.dict(
            os.environ, {"FAKE_PROJECT_CWD": str(self.project)}, clear=False
        ):
            result = MODULE.verify_worker_task(
                thread_id="thread-test",
                expected_runtime_project_id=PROJECT_ID,
                cwd=str(self.project),
                model="gpt-5.6-terra",
                thinking="high",
                configuration_mode="global-config",
                approval_policy="on-request",
                sandbox_mode="danger-full-access",
                codex_executable=str(self.fake_codex),
            )
        self.assertEqual("kepler.worker-task-verification/v1", result["schemaVersion"])
        self.assertTrue(result["verified"])
        self.assertEqual("thread-test", result["threadId"])
        self.assertEqual(PROJECT_ID, result["expectedRuntimeProjectId"])
        self.assertEqual(PROJECT_ID, result["actualRuntimeProjectId"])
        self.assertEqual("danger-full-access", result["sandboxMode"])
        self.assertEqual("dangerFullAccess", result["sandbox"]["type"])
        self.assertTrue(result["empty"])

    def test_verify_worker_rejects_managed_workspace_sandbox(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_RESUME_SANDBOX": "workspaceWrite",
            },
            clear=False,
        ):
            with self.assertRaisesRegex(
                MODULE.DispatchError, "did not preserve the effective sandbox_mode"
            ):
                MODULE.verify_worker_task(
                    thread_id="thread-test",
                    expected_runtime_project_id=PROJECT_ID,
                    cwd=str(self.project),
                    model="gpt-5.6-terra",
                    thinking="high",
                    configuration_mode="global-config",
                    approval_policy="on-request",
                    sandbox_mode="danger-full-access",
                    codex_executable=str(self.fake_codex),
                )

    def test_verify_worker_rejects_prompted_task(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_RESUME_NONEMPTY": "1",
            },
            clear=False,
        ):
            with self.assertRaisesRegex(
                MODULE.DispatchError, "must be verified before its prompt"
            ):
                MODULE.verify_worker_task(
                    thread_id="thread-test",
                    expected_runtime_project_id=PROJECT_ID,
                    cwd=str(self.project),
                    model="gpt-5.6-terra",
                    thinking="high",
                    configuration_mode="global-config",
                    approval_policy="on-request",
                    sandbox_mode="danger-full-access",
                    codex_executable=str(self.fake_codex),
                )

    def test_planner_bootstrap_is_hard_bound_and_preserves_config(self) -> None:
        result = MODULE.bootstrap_planner_task(
            cwd=str(self.project),
            expected_runtime_project_id=PROJECT_ID,
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
            expected_runtime_project_id=PROJECT_ID,
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
            expected_runtime_project_id=PROJECT_ID,
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

    def test_only_delivery_tool_can_accept_a_prompt(self) -> None:
        for tool in MODULE.TOOLS:
            properties = tool["inputSchema"]["properties"]
            if tool["name"] == "deliver_herdr_worker_prompt":
                self.assertIn("prompt", properties)
            else:
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
        verifier = MODULE.VERIFY_WORKER_TOOL["inputSchema"]
        self.assertIn("expected_runtime_project_id", verifier["required"])
        self.assertIn("configuration_mode", verifier["required"])
        self.assertIn("approval_policy", verifier["required"])
        self.assertIn(
            "expected_runtime_project_id",
            MODULE.WORKER_TOOL["inputSchema"]["required"],
        )

    def test_cli_project_catalog_and_registration_are_exact_and_idempotent(self) -> None:
        project = {
            "id": "cli-project-existing",
            "name": "Existing",
            "roots": [{"path": str(self.project)}],
            "metadata": {},
            "createdAt": 1,
            "updatedAt": 1,
            "position": 0,
        }
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECTS": json.dumps([project]),
            },
            clear=False,
        ):
            catalog = MODULE.list_cli_projects(codex_executable=str(self.fake_codex))
            registered = MODULE.register_cli_project(
                cwd=str(self.project),
                name="Renamed",
                confirmed=True,
                codex_executable=str(self.fake_codex),
            )
        self.assertEqual(2, catalog["schemaVersion"])
        self.assertEqual("kepler.cli-project-catalog/v1", catalog["catalogSchema"])
        self.assertEqual("cli-project-existing", catalog["projects"][0]["projectId"])
        self.assertFalse(registered["created"])
        self.assertEqual("cli-project-existing", registered["project"]["id"])

        with mock.patch.dict(
            os.environ,
            {"HERDR_ENV": "1", "FAKE_PROJECTS": "[]"},
            clear=False,
        ):
            created = MODULE.register_cli_project(
                cwd=str(self.project),
                name="CLI project",
                confirmed=True,
                codex_executable=str(self.fake_codex),
            )
        self.assertTrue(created["created"])
        self.assertEqual("cli-project-test", created["project"]["id"])

    def test_cli_project_registration_requires_explicit_confirmation(self) -> None:
        with mock.patch.dict(os.environ, {"HERDR_ENV": "1"}, clear=False):
            with self.assertRaisesRegex(MODULE.DispatchError, "confirmed must be true"):
                MODULE.register_cli_project(
                    cwd=str(self.project),
                    name="CLI project",
                    confirmed=False,
                    codex_executable=str(self.fake_codex),
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
                        "expected_runtime_project_id": PROJECT_ID,
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
                        "expected_runtime_project_id": PROJECT_ID,
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
        self.assertEqual(PROJECT_ID, receipt["actualRuntimeProjectId"])
        self.assertEqual("global-config", receipt["configurationMode"])
        self.assertIsNone(receipt["permissionProfile"])

    def test_bootstrap_fails_closed_on_project_mismatch(self) -> None:
        with mock.patch.dict(
            os.environ, {"FAKE_START_PROJECT_ID": "project-b"}, clear=False
        ):
            with self.assertRaisesRegex(
                MODULE.DispatchError,
                "thread/start projectId does not match expected_runtime_project_id",
            ):
                MODULE.bootstrap_worker_task(
                    cwd=str(self.project),
                    expected_runtime_project_id=PROJECT_ID,
                    title="Worker task",
                    model="gpt-5.6-terra",
                    thinking="high",
                    codex_executable=str(self.fake_codex),
                )

    def test_hub_dispatcher_creates_and_continues_worker_in_owner_project(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "FAKE_DISPATCHER_PROJECT_ID": "hub-b",
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_RESUME_NONEMPTY": "1",
            },
            clear=False,
        ):
            created = MODULE.bootstrap_worker_task(
                cwd=str(self.project),
                expected_runtime_project_id=PROJECT_ID,
                title="Repository worker",
                model="gpt-5.6-terra",
                thinking="high",
                codex_executable=str(self.fake_codex),
            )
            continued = MODULE.verify_worker_task(
                thread_id=created["threadId"],
                expected_runtime_project_id=PROJECT_ID,
                cwd=str(self.project),
                model="gpt-5.6-terra",
                thinking="high",
                configuration_mode="global-config",
                approval_policy="on-request",
                sandbox_mode="danger-full-access",
                require_empty=False,
                codex_executable=str(self.fake_codex),
            )
        self.assertEqual(PROJECT_ID, created["actualRuntimeProjectId"])
        self.assertEqual(PROJECT_ID, continued["actualRuntimeProjectId"])
        self.assertFalse(continued["empty"])

    def test_empty_worker_verification_reapplies_terra_runtime(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"FAKE_PROJECT_CWD": str(self.project)},
            clear=False,
        ):
            verified = MODULE.verify_worker_task(
                thread_id="thread-test",
                expected_runtime_project_id=PROJECT_ID,
                cwd=str(self.project),
                model="gpt-5.6-terra",
                thinking="high",
                configuration_mode="global-config",
                approval_policy="on-request",
                sandbox_mode="danger-full-access",
                require_empty=True,
                codex_executable=str(self.fake_codex),
            )
        self.assertTrue(verified["verified"])
        self.assertTrue(verified["empty"])
        self.assertEqual("gpt-5.6-terra", verified["model"])
        self.assertEqual("high", verified["thinking"])

    def test_continuation_fails_closed_on_project_reassociation(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_RESUME_PROJECT_ID": "hub-b",
                "FAKE_RESUME_NONEMPTY": "1",
            },
            clear=False,
        ):
            with self.assertRaisesRegex(
                MODULE.DispatchError,
                "thread/resume projectId does not match expected_runtime_project_id",
            ):
                MODULE.verify_worker_task(
                    thread_id="thread-test",
                    expected_runtime_project_id=PROJECT_ID,
                    cwd=str(self.project),
                    model="gpt-5.6-terra",
                    thinking="high",
                    configuration_mode="global-config",
                    approval_policy="on-request",
                    sandbox_mode="danger-full-access",
                    require_empty=False,
                    codex_executable=str(self.fake_codex),
                )

    def test_post_delivery_verification_rejects_empty_task(self) -> None:
        with mock.patch.dict(
            os.environ, {"FAKE_PROJECT_CWD": str(self.project)}, clear=False
        ):
            with self.assertRaisesRegex(
                MODULE.DispatchError,
                "post-delivery verification requires a turn",
            ):
                MODULE.verify_worker_task(
                    thread_id="thread-test",
                    expected_runtime_project_id=PROJECT_ID,
                    cwd=str(self.project),
                    model="gpt-5.6-terra",
                    thinking="high",
                    configuration_mode="global-config",
                    approval_policy="on-request",
                    sandbox_mode="danger-full-access",
                    require_empty=False,
                    codex_executable=str(self.fake_codex),
                )

    def _attach_worker(self, cwd: Path | None = None) -> dict[str, object]:
        worker_cwd = cwd or self.project
        with mock.patch.dict(
            os.environ,
            {"HERDR_ENV": "1", "FAKE_PROJECT_CWD": str(worker_cwd)},
            clear=False,
        ):
            return MODULE.attach_herdr_worker(
                thread_id="thread-test",
                expected_runtime_project_id=PROJECT_ID,
                cwd=str(worker_cwd),
                model="gpt-5.6-terra",
                thinking="high",
                configuration_mode="global-config",
                approval_policy="on-request",
                sandbox_mode="danger-full-access",
                workspace_label="CDM worker",
                agent_name="worker-agent",
                codex_executable=str(self.fake_codex),
                herdr_executable=str(self.fake_herdr),
            )

    def test_attach_herdr_worker_resumes_exact_empty_task_without_prompt(self) -> None:
        log = self.root / "herdr.log"
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_HERDR_LOG": str(log),
            },
            clear=False,
        ):
            result = self._attach_worker()
        self.assertEqual("kepler.herdr-attachment/v1", result["schema_version"])
        self.assertEqual("thread-test", result["resumed_task_id"])
        self.assertEqual(str(self.project.resolve()), result["worker_cwd"])
        self.assertEqual(19, result["protocol"])
        self.assertEqual("term1", result["terminal_id"])
        self.assertRegex(result["resume_argv_sha256"], r"^[0-9a-f]{64}$")
        self.assertFalse(result["workspace_owned"])
        self.assertEqual("shared-control-workspace", result["attachment_mode"])
        self.assertEqual("w0:t0", result["control_tab_id"])
        self.assertEqual("w0:p0", result["control_pane_id"])
        commands = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
        self.assertIn(["pane", "current", "--current"], commands)
        self.assertIn(
            [
                "tab",
                "create",
                "--workspace",
                "w0",
                "--cwd",
                str(self.project.resolve()),
                "--label",
                "CDM worker",
                "--no-focus",
            ],
            commands,
        )
        self.assertFalse(any(command[:2] == ["workspace", "create"] for command in commands))
        self.assertIn(
            [
                "agent",
                "start",
                "worker-agent",
                "--kind",
                "codex",
                "--pane",
                "w0:p1",
                "--",
                "--no-alt-screen",
                "-c",
                "check_for_update_on_startup=false",
                "-m",
                "gpt-5.6-terra",
                "-c",
                'model_reasoning_effort="high"',
                "-s",
                "danger-full-access",
                "-a",
                "on-request",
                "resume",
                "thread-test",
            ],
            commands,
        )
        self.assertFalse(any(command[:2] == ["agent", "prompt"] for command in commands))
        self.assertEqual("gpt-5.6-terra", result["model"])
        self.assertEqual("high", result["thinking"])

    def test_attach_herdr_worker_refuses_nonempty_or_wrong_session_and_rolls_back(self) -> None:
        log = self.root / "herdr.log"
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_RESUME_NONEMPTY": "1",
                "FAKE_HERDR_LOG": str(log),
            },
            clear=False,
        ):
            with self.assertRaisesRegex(MODULE.DispatchError, "must be verified before its prompt"):
                self._attach_worker()
        self.assertFalse(log.exists())
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_HERDR_SESSION": "wrong-thread",
                "FAKE_HERDR_LOG": str(log),
            },
            clear=False,
        ):
            with self.assertRaisesRegex(MODULE.DispatchError, "session does not match"):
                self._attach_worker()
        commands = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(["tab", "close", "w0:t1"], commands[-1])

    def test_attach_herdr_worker_refuses_wrong_workspace_cwd(self) -> None:
        wrong_cwd = self.root / "wrong"
        wrong_cwd.mkdir()
        log = self.root / "herdr.log"
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_HERDR_CWD": str(wrong_cwd),
                "FAKE_HERDR_LOG": str(log),
            },
            clear=False,
        ):
            with self.assertRaisesRegex(MODULE.DispatchError, "tab/create cwd"):
                self._attach_worker()
        commands = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(["tab", "close", "w0:t1"], commands[-1])

    def test_attach_herdr_worker_requires_protocol_nineteen(self) -> None:
        log = self.root / "herdr.log"
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_HERDR_PROTOCOL": "18",
                "FAKE_HERDR_LOG": str(log),
            },
            clear=False,
        ):
            with self.assertRaisesRegex(MODULE.DispatchError, "protocol 19"):
                self._attach_worker()
        commands = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
        self.assertEqual([["api", "schema", "--json"]], commands)

    def test_deliver_herdr_prompt_records_exact_task_without_monitoring(self) -> None:
        marker = self.root / "prompt.txt"
        log = self.root / "delivery.log"
        prompt = "ContextPack: synthetic-unit\nReturn only the WorkerResult."
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_PROMPT_MARKER": str(marker),
                "FAKE_HERDR_LOG": str(log),
            },
            clear=False,
        ):
            attachment = self._attach_worker()
            result = MODULE.deliver_herdr_worker_prompt(
                thread_id="thread-test",
                expected_runtime_project_id=PROJECT_ID,
                cwd=str(self.project),
                delivery_id="synthetic-unit-r1",
                prompt=prompt,
                herdr_attachment=attachment,
                codex_executable=str(self.fake_codex),
                herdr_executable=str(self.fake_herdr),
            )
            duplicate = MODULE.deliver_herdr_worker_prompt(
                thread_id="thread-test",
                expected_runtime_project_id=PROJECT_ID,
                cwd=str(self.project),
                delivery_id="synthetic-unit-r1",
                prompt=prompt,
                herdr_attachment=attachment,
                codex_executable=str(self.fake_codex),
                herdr_executable=str(self.fake_herdr),
            )
        self.assertTrue(result["delivered"])
        self.assertFalse(result["deduplicated"])
        self.assertEqual(PROJECT_ID, result["actualRuntimeProjectId"])
        self.assertEqual(0, result["turnCountBefore"])
        self.assertEqual(1, result["turnCountAfter"])
        self.assertNotIn(prompt, json.dumps(result))
        self.assertTrue(duplicate["deduplicated"])
        commands = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
        prompts = [command for command in commands if command[:2] == ["agent", "prompt"]]
        self.assertEqual([["agent", "prompt", "worker-agent", prompt]], prompts)

    def test_deliver_herdr_prompt_fails_closed_on_project_drift(self) -> None:
        marker = self.root / "prompt.txt"
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_PROMPT_MARKER": str(marker),
            },
            clear=False,
        ):
            attachment = self._attach_worker()
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_PROMPT_MARKER": str(marker),
                "FAKE_RESUME_PROJECT_ID": "wrong-project",
            },
            clear=False,
        ):
            with self.assertRaisesRegex(MODULE.DispatchError, "thread/read projectId"):
                MODULE.deliver_herdr_worker_prompt(
                    thread_id="thread-test",
                    expected_runtime_project_id=PROJECT_ID,
                    cwd=str(self.project),
                    delivery_id="synthetic-unit-r1",
                    prompt="ContextPack",
                    herdr_attachment=attachment,
                    codex_executable=str(self.fake_codex),
                    herdr_executable=str(self.fake_herdr),
                )
        self.assertFalse(marker.exists())

    def test_collect_herdr_worker_result_returns_only_final_response(self) -> None:
        marker = self.root / "prompt.txt"
        worker_result = "apiVersion: kepler.dev/v1\nkind: WorkerResult\nstatus: completed"
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(self.project),
            },
            clear=False,
        ):
            attachment = self._attach_worker()
        marker.write_text("ContextPack", encoding="utf-8")
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_PROMPT_MARKER": str(marker),
                "FAKE_RESULT_TEXT": worker_result,
                "FAKE_TURN_STATUS": "completed",
                "FAKE_HERDR_STATUS": "done",
            },
            clear=False,
        ):
            collected = MODULE.collect_herdr_worker_result(
                thread_id="thread-test",
                expected_runtime_project_id=PROJECT_ID,
                cwd=str(self.project),
                herdr_attachment=attachment,
                codex_executable=str(self.fake_codex),
                herdr_executable=str(self.fake_herdr),
            )
        self.assertEqual(worker_result, collected["finalResponse"])
        self.assertEqual("completed", collected["turnStatus"])
        self.assertNotIn("ContextPack", json.dumps(collected))

    def test_collect_herdr_worker_result_refuses_active_turn(self) -> None:
        marker = self.root / "prompt.txt"
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(self.project),
            },
            clear=False,
        ):
            attachment = self._attach_worker()
        marker.write_text("ContextPack", encoding="utf-8")
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_PROMPT_MARKER": str(marker),
                "FAKE_HERDR_STATUS": "idle",
            },
            clear=False,
        ):
            with self.assertRaisesRegex(MODULE.DispatchError, "not completed"):
                MODULE.collect_herdr_worker_result(
                    thread_id="thread-test",
                    expected_runtime_project_id=PROJECT_ID,
                    cwd=str(self.project),
                    herdr_attachment=attachment,
                    codex_executable=str(self.fake_codex),
                    herdr_executable=str(self.fake_herdr),
                )

    def test_cleanup_refuses_active_worker_or_wrong_attachment_task(self) -> None:
        attachment = self._attach_worker()
        with mock.patch.dict(
            os.environ,
            {"HERDR_ENV": "1", "FAKE_PROJECT_CWD": str(self.project)},
            clear=False,
        ):
            with self.assertRaisesRegex(MODULE.DispatchError, "explicit Kepler cleanup authorization"):
                MODULE.cleanup_herdr_worker(
                    thread_id="thread-test",
                    expected_runtime_project_id=PROJECT_ID,
                    project_path=str(self.project),
                    worker_cwd=str(self.project),
                    mode="local",
                    herdr_attachment=attachment,
                    remove_worktree=False,
                    authorized=False,
                    codex_executable=str(self.fake_codex),
                    herdr_executable=str(self.fake_herdr),
                )
            with self.assertRaisesRegex(MODULE.DispatchError, "Local mode"):
                MODULE.cleanup_herdr_worker(
                    thread_id="thread-test",
                    expected_runtime_project_id=PROJECT_ID,
                    project_path=str(self.project),
                    worker_cwd=str(self.project),
                    mode="local",
                    herdr_attachment=attachment,
                    remove_worktree=True,
                    authorized=True,
                    codex_executable=str(self.fake_codex),
                    herdr_executable=str(self.fake_herdr),
                )
        log = self.root / "cleanup.log"
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(self.project),
                "FAKE_RESUME_ACTIVE": "1",
                "FAKE_HERDR_LOG": str(log),
            },
            clear=False,
        ):
            with self.assertRaisesRegex(MODULE.DispatchError, "Codex worker is active"):
                MODULE.cleanup_herdr_worker(
                    thread_id="thread-test",
                    expected_runtime_project_id=PROJECT_ID,
                    project_path=str(self.project),
                    worker_cwd=str(self.project),
                    mode="local",
                    herdr_attachment=attachment,
                    remove_worktree=False,
                    authorized=True,
                    codex_executable=str(self.fake_codex),
                    herdr_executable=str(self.fake_herdr),
                )
        commands = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
        self.assertFalse(any(command[:2] == ["workspace", "close"] for command in commands))
        self.assertFalse(any(command[:2] == ["tab", "close"] for command in commands))
        wrong = dict(attachment)
        wrong["resumed_task_id"] = "other-task"
        with mock.patch.dict(
            os.environ,
            {"HERDR_ENV": "1", "FAKE_PROJECT_CWD": str(self.project)},
            clear=False,
        ):
            with self.assertRaisesRegex(MODULE.DispatchError, "resumed_task_id"):
                MODULE.cleanup_herdr_worker(
                    thread_id="thread-test",
                    expected_runtime_project_id=PROJECT_ID,
                    project_path=str(self.project),
                    worker_cwd=str(self.project),
                    mode="local",
                    herdr_attachment=wrong,
                    remove_worktree=False,
                    authorized=True,
                    codex_executable=str(self.fake_codex),
                    herdr_executable=str(self.fake_herdr),
                )

    def test_cleanup_refuses_dirty_or_unmerged_worktree_before_close_or_archive(self) -> None:
        subprocess.run(["git", "init", "-q"], cwd=self.project, check=True)
        subprocess.run(["git", "config", "user.email", "kepler@example.test"], cwd=self.project, check=True)
        subprocess.run(["git", "config", "user.name", "Kepler"], cwd=self.project, check=True)
        (self.project / "README.md").write_text("base\n", encoding="utf-8")
        subprocess.run(["git", "add", "README.md"], cwd=self.project, check=True)
        subprocess.run(["git", "commit", "-qm", "base"], cwd=self.project, check=True)
        worktree = self.root / "worker-worktree"
        subprocess.run(["git", "worktree", "add", "-q", "-b", "worker", str(worktree)], cwd=self.project, check=True)
        log = self.root / "cleanup.log"
        with mock.patch.dict(
            os.environ,
            {"HERDR_ENV": "1", "FAKE_PROJECT_CWD": str(worktree)},
            clear=False,
        ):
            attachment = self._attach_worker(worktree)
        (worktree / "dirty.txt").write_text("dirty\n", encoding="utf-8")
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(worktree),
                "FAKE_HERDR_LOG": str(log),
            },
            clear=False,
        ):
            with self.assertRaisesRegex(MODULE.DispatchError, "worktree is dirty"):
                MODULE.cleanup_herdr_worker(
                    thread_id="thread-test",
                    expected_runtime_project_id=PROJECT_ID,
                    project_path=str(self.project),
                    worker_cwd=str(worktree),
                    mode="worktree",
                    herdr_attachment=attachment,
                    remove_worktree=True,
                    authorized=True,
                    codex_executable=str(self.fake_codex),
                    herdr_executable=str(self.fake_herdr),
                )
        commands = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
        self.assertFalse(any(command[:2] == ["workspace", "close"] for command in commands))
        self.assertFalse(any(command[:2] == ["tab", "close"] for command in commands))
        (worktree / "dirty.txt").unlink()
        (worktree / "unmerged.txt").write_text("unmerged\n", encoding="utf-8")
        subprocess.run(["git", "add", "unmerged.txt"], cwd=worktree, check=True)
        subprocess.run(["git", "commit", "-qm", "unmerged"], cwd=worktree, check=True)
        unmerged_log = self.root / "cleanup-unmerged.log"
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(worktree),
                "FAKE_HERDR_LOG": str(unmerged_log),
            },
            clear=False,
        ):
            with self.assertRaisesRegex(MODULE.DispatchError, "not merged"):
                MODULE.cleanup_herdr_worker(
                    thread_id="thread-test",
                    expected_runtime_project_id=PROJECT_ID,
                    project_path=str(self.project),
                    worker_cwd=str(worktree),
                    mode="worktree",
                    herdr_attachment=attachment,
                    remove_worktree=True,
                    authorized=True,
                    codex_executable=str(self.fake_codex),
                    herdr_executable=str(self.fake_herdr),
                )
        commands = [json.loads(line) for line in unmerged_log.read_text(encoding="utf-8").splitlines()]
        self.assertFalse(any(command[:2] == ["workspace", "close"] for command in commands))
        self.assertFalse(any(command[:2] == ["tab", "close"] for command in commands))

    def test_cleanup_closes_archives_and_removes_only_merged_worktree(self) -> None:
        subprocess.run(["git", "init", "-q"], cwd=self.project, check=True)
        subprocess.run(["git", "config", "user.email", "kepler@example.test"], cwd=self.project, check=True)
        subprocess.run(["git", "config", "user.name", "Kepler"], cwd=self.project, check=True)
        (self.project / "README.md").write_text("base\n", encoding="utf-8")
        subprocess.run(["git", "add", "README.md"], cwd=self.project, check=True)
        subprocess.run(["git", "commit", "-qm", "base"], cwd=self.project, check=True)
        worktree = self.root / "worker-worktree"
        subprocess.run(
            ["git", "worktree", "add", "-q", "-b", "worker", str(worktree)],
            cwd=self.project,
            check=True,
        )
        with mock.patch.dict(
            os.environ,
            {"HERDR_ENV": "1", "FAKE_PROJECT_CWD": str(worktree)},
            clear=False,
        ):
            attachment = self._attach_worker(worktree)

        herdr_log = self.root / "cleanup-success.log"
        codex_log = self.root / "codex-success.log"
        with mock.patch.dict(
            os.environ,
            {
                "HERDR_ENV": "1",
                "FAKE_PROJECT_CWD": str(worktree),
                "FAKE_HERDR_LOG": str(herdr_log),
                "FAKE_CODEX_LOG": str(codex_log),
            },
            clear=False,
        ), mock.patch.object(
            MODULE,
            "_worktree_safety_snapshot",
            wraps=MODULE._worktree_safety_snapshot,
        ) as safety_snapshot:
            result = MODULE.cleanup_herdr_worker(
                thread_id="thread-test",
                expected_runtime_project_id=PROJECT_ID,
                project_path=str(self.project),
                worker_cwd=str(worktree),
                mode="worktree",
                herdr_attachment=attachment,
                remove_worktree=True,
                authorized=True,
                codex_executable=str(self.fake_codex),
                herdr_executable=str(self.fake_herdr),
            )

        self.assertTrue(result["herdrWorkspacePreserved"])
        self.assertTrue(result["herdrWorkerTabClosed"])
        self.assertTrue(result["taskArchived"])
        self.assertTrue(result["worktreeRemoved"])
        self.assertTrue(result["branchPreserved"])
        self.assertEqual(attachment, result["herdrAttachment"])
        self.assertEqual(2, safety_snapshot.call_count)
        self.assertFalse(worktree.exists())
        branches = subprocess.run(
            ["git", "branch", "--list", "worker"],
            cwd=self.project,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertIn("worker", branches)
        commands = [json.loads(line) for line in herdr_log.read_text(encoding="utf-8").splitlines()]
        self.assertIn(["tab", "close", "w0:t1"], commands)
        self.assertNotIn(["workspace", "close", "w0"], commands)
        self.assertEqual("archive thread-test\n", codex_log.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
