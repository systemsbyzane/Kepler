#!/usr/bin/env python3
"""Narrow MCP bridge for permission-preserving Codex worker-task creation."""

from __future__ import annotations

import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any, Dict, Iterable, Optional


SERVER_NAME = "kepler-dispatch"
SERVER_VERSION = "1.1.1"
DEFAULT_TIMEOUT_SECONDS = 20.0
HERDR_TIMEOUT_SECONDS = 45.0
THINKING_LEVELS = {"low", "medium", "high", "xhigh", "max", "ultra"}
SAFE_IDENTIFIER = re.compile(r"^[A-Za-z0-9_.:+-]+$")
HERDR_AGENT_NAME = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
SOL_MODEL = "gpt-5.6-sol"
SOL_THINKING = "high"
CONFIGURATION_MODES = {"global-config", "permission-profile"}
WORKER_MODES = {"local", "worktree"}
HERDR_AGENT_KIND = "codex"


class DispatchError(RuntimeError):
    """Raised when a worker task cannot be created safely."""


def _write_json(stream: Any, payload: Dict[str, Any]) -> None:
    stream.write(json.dumps(payload, separators=(",", ":")) + "\n")
    stream.flush()


def _resolve_codex_executable(explicit: Optional[str] = None) -> str:
    candidates = [
        explicit,
        os.environ.get("KEPLER_CODEX_CLI_PATH"),
        os.environ.get("CODEX_CLI_PATH"),
        shutil.which("codex"),
        "/Applications/ChatGPT.app/Contents/Resources/codex",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return str(Path(candidate).resolve())
    raise DispatchError("Codex CLI executable was not found")


def _resolve_herdr_executable(explicit: Optional[str] = None) -> str:
    candidates = [
        explicit,
        os.environ.get("KEPLER_HERDR_CLI_PATH"),
        os.environ.get("HERDR_CLI_PATH"),
        os.environ.get("HERDR_BIN_PATH"),
        shutil.which("herdr"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return str(Path(candidate).resolve())
    raise DispatchError("Herdr CLI executable was not found")


def _validated_herdr_identifier(value: Any, field: str) -> str:
    if not isinstance(value, str):
        raise DispatchError(f"{field} must be a string")
    normalized = value.strip()
    if not normalized or len(normalized) > 200:
        raise DispatchError(f"{field} must contain 1 to 200 characters")
    if not SAFE_IDENTIFIER.fullmatch(normalized):
        raise DispatchError(f"{field} contains unsupported characters")
    return normalized


def _validated_herdr_label(value: Any) -> str:
    if not isinstance(value, str):
        raise DispatchError("workspace_label must be a string")
    normalized = value.strip()
    if not normalized or len(normalized) > 120:
        raise DispatchError("workspace_label must contain 1 to 120 characters")
    if any(ord(character) < 32 or ord(character) == 127 for character in normalized):
        raise DispatchError("workspace_label contains control characters")
    return normalized


def _validated_herdr_agent_name(value: Any) -> str:
    if not isinstance(value, str) or not HERDR_AGENT_NAME.fullmatch(value):
        raise DispatchError(
            "agent_name must match [a-z][a-z0-9_-]{0,31}"
        )
    return value


def _require_herdr_environment() -> None:
    if os.environ.get("HERDR_ENV") != "1":
        raise DispatchError("HERDR_ENV=1 is required for Herdr worker attachment")


def _run_herdr_json(executable: str, arguments: list[str]) -> Dict[str, Any]:
    try:
        completed = subprocess.run(
            [executable, *arguments],
            check=False,
            capture_output=True,
            text=True,
            timeout=HERDR_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise DispatchError(f"Herdr command failed to run: {error}") from error
    if completed.returncode != 0:
        diagnostic = completed.stderr.strip() or completed.stdout.strip()
        raise DispatchError(f"Herdr command failed: {diagnostic or completed.returncode}")
    response = completed.stdout.strip()
    if not response:
        raise DispatchError("Herdr command did not return a JSON response")
    try:
        payload = json.loads(response)
    except json.JSONDecodeError as error:
        raise DispatchError("Herdr command returned invalid JSON") from error
    if not isinstance(payload, dict):
        raise DispatchError("Herdr command returned an invalid response")
    return payload


def _run_herdr(executable: str, arguments: list[str]) -> Dict[str, Any]:
    payload = _run_herdr_json(executable, arguments)
    result = payload.get("result")
    if not isinstance(result, dict):
        raise DispatchError("Herdr command returned an invalid protocol response")
    return result


def _herdr_agent_info(executable: str, target: str) -> Dict[str, Any]:
    result = _run_herdr(executable, ["agent", "get", target])
    agent = result.get("agent")
    if not isinstance(agent, dict):
        raise DispatchError("Herdr agent/get did not return an agent")
    return agent


def _verify_herdr_capability(executable: str) -> Dict[str, Any]:
    schema = _run_herdr_json(executable, ["api", "schema", "--json"])
    protocol = schema.get("protocol")
    schemas = schema.get("schemas")
    if not isinstance(protocol, int) or protocol < 19:
        raise DispatchError("Herdr API protocol 19 or newer is required")
    if not isinstance(schemas, dict) or not schemas:
        raise DispatchError("Herdr API schema did not return protocol schemas")
    version_result = _run_herdr_json(executable, ["status", "server", "--json"])
    version = version_result.get("version")
    if not isinstance(version, str) or not version.strip():
        raise DispatchError("Herdr server status did not return a version")
    if version_result.get("protocol") != protocol:
        raise DispatchError("Herdr server protocol does not match the API schema")
    return {"version": version, "protocol": protocol}


def _validate_herdr_agent(
    agent: Dict[str, Any],
    *,
    workspace_id: str,
    tab_id: str,
    pane_id: str,
    agent_name: str,
    worker_cwd: str,
    thread_id: str,
    require_terminal_state: bool,
) -> None:
    for field, expected in (
        ("workspace_id", workspace_id),
        ("tab_id", tab_id),
        ("pane_id", pane_id),
        ("name", agent_name),
        ("agent", HERDR_AGENT_KIND),
    ):
        if agent.get(field) != expected:
            raise DispatchError(f"Herdr agent {field} does not match the attachment")
    try:
        actual_cwd = str(Path(agent.get("cwd", "")).expanduser().resolve(strict=True))
    except (OSError, RuntimeError):
        raise DispatchError("Herdr agent did not return a resolvable cwd")
    if actual_cwd != worker_cwd:
        raise DispatchError("Herdr agent cwd does not match the exact worker path")
    session = agent.get("agent_session")
    if not isinstance(session, dict) or session.get("value") != thread_id:
        raise DispatchError("Herdr agent session does not match the exact worker task")
    if require_terminal_state and agent.get("agent_status") not in {"idle", "done"}:
        raise DispatchError("Herdr worker is active or not in a terminal state")


def _close_herdr_workspace(executable: str, workspace_id: str) -> None:
    result = _run_herdr(executable, ["workspace", "close", workspace_id])
    if result.get("type") != "ok":
        raise DispatchError("Herdr workspace/close did not confirm closure")


def _validated_inputs(
    cwd: str,
    title: str,
    model: str,
    thinking: str,
    permission_profile: Optional[str],
) -> Dict[str, Any]:
    project_path = Path(cwd).expanduser().resolve()
    if not project_path.is_dir():
        raise DispatchError("cwd must resolve to an existing directory")
    if not title.strip() or len(title) > 200:
        raise DispatchError("title must contain 1 to 200 characters")
    if not SAFE_IDENTIFIER.fullmatch(model):
        raise DispatchError("model contains unsupported characters")
    if thinking not in THINKING_LEVELS:
        raise DispatchError("thinking must be one of: " + ", ".join(sorted(THINKING_LEVELS)))
    if permission_profile is not None and not SAFE_IDENTIFIER.fullmatch(permission_profile):
        raise DispatchError("permission_profile contains unsupported characters")
    return {
        "cwd": str(project_path),
        "title": title.strip(),
        "model": model,
        "thinking": thinking,
        "permission_profile": permission_profile,
    }


def _validated_runtime_project_id(value: str) -> str:
    if not isinstance(value, str):
        raise DispatchError("expected_runtime_project_id must be a string")
    project_id = value.strip()
    if not project_id or len(project_id) > 512:
        raise DispatchError(
            "expected_runtime_project_id must contain 1 to 512 characters"
        )
    if any(ord(character) < 32 or ord(character) == 127 for character in project_id):
        raise DispatchError("expected_runtime_project_id contains control characters")
    return project_id


class AppServerClient:
    def __init__(self, executable: str, timeout: float = DEFAULT_TIMEOUT_SECONDS) -> None:
        self.executable = executable
        self.timeout = timeout
        self.process: Optional[subprocess.Popen[str]] = None
        self._next_id = 1
        self._messages: "queue.Queue[Optional[str]]" = queue.Queue()
        self._stderr: deque[str] = deque(maxlen=40)
        self._stdout_thread: Optional[threading.Thread] = None
        self._stderr_thread: Optional[threading.Thread] = None

    def __enter__(self) -> "AppServerClient":
        self.process = subprocess.Popen(
            [self.executable, "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert self.process.stdout is not None and self.process.stderr is not None
        self._stdout_thread = threading.Thread(target=self._drain_stdout, daemon=True)
        self._stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self._stdout_thread.start()
        self._stderr_thread.start()
        self.request(
            "initialize",
            {
                "clientInfo": {
                    "name": "kepler",
                    "title": "Kepler",
                    "version": SERVER_VERSION,
                },
                "capabilities": {"experimentalApi": True},
            },
        )
        self.notify("initialized", {})
        return self

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        if self.process is None:
            return
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None:
                stream.close()
        for thread in (self._stdout_thread, self._stderr_thread):
            if thread is not None:
                thread.join(timeout=1)

    def _drain_stdout(self) -> None:
        assert self.process is not None and self.process.stdout is not None
        for line in self.process.stdout:
            self._messages.put(line)
        self._messages.put(None)

    def _drain_stderr(self) -> None:
        assert self.process is not None and self.process.stderr is not None
        for line in self.process.stderr:
            self._stderr.append(line.rstrip())

    def _diagnostic(self) -> str:
        return " | ".join(self._stderr) or "no app-server diagnostic was emitted"

    def notify(self, method: str, params: Dict[str, Any]) -> None:
        self._send({"method": method, "params": params})

    def request(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        request_id = self._next_id
        self._next_id += 1
        self._send({"method": method, "id": request_id, "params": params})
        deadline = time.monotonic() + self.timeout
        while True:
            message = self._read(deadline)
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise DispatchError(f"{method} failed: {message['error']}")
            result = message.get("result")
            if not isinstance(result, dict):
                raise DispatchError(f"{method} returned an invalid response")
            return result

    def _send(self, payload: Dict[str, Any]) -> None:
        if self.process is None or self.process.stdin is None or self.process.poll() is not None:
            raise DispatchError("app-server is not running: " + self._diagnostic())
        _write_json(self.process.stdin, payload)

    def _read(self, deadline: float) -> Dict[str, Any]:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise DispatchError("app-server response timed out: " + self._diagnostic())
        try:
            line = self._messages.get(timeout=remaining)
        except queue.Empty:
            raise DispatchError("app-server response timed out: " + self._diagnostic())
        if line is None:
            raise DispatchError("app-server closed unexpectedly: " + self._diagnostic())
        try:
            message = json.loads(line)
        except json.JSONDecodeError as error:
            raise DispatchError("app-server emitted invalid JSON") from error
        if not isinstance(message, dict):
            raise DispatchError("app-server emitted a non-object response")
        return message


def _allowed_profiles(items: Iterable[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    return {
        str(item.get("id")): item
        for item in items
        if isinstance(item, dict) and item.get("allowed") is True and item.get("id")
    }


def _legacy_sandbox_receipt(sandbox_mode: str) -> str:
    mapping = {
        "danger-full-access": "dangerFullAccess",
        "workspace-write": "workspaceWrite",
        "read-only": "readOnly",
    }
    receipt = mapping.get(sandbox_mode)
    if receipt is None:
        raise DispatchError(f"unsupported effective sandbox_mode {sandbox_mode!r}")
    return receipt


def _validated_verification_inputs(
    *,
    thread_id: str,
    expected_runtime_project_id: str,
    cwd: str,
    model: str,
    thinking: str,
    configuration_mode: str,
    approval_policy: Any,
    permission_profile: Optional[str],
    sandbox_mode: Optional[str],
) -> Dict[str, Any]:
    values = _validated_inputs(cwd, thread_id, model, thinking, permission_profile)
    values["expected_runtime_project_id"] = _validated_runtime_project_id(
        expected_runtime_project_id
    )
    if not SAFE_IDENTIFIER.fullmatch(thread_id):
        raise DispatchError("thread_id contains unsupported characters")
    if configuration_mode not in CONFIGURATION_MODES:
        raise DispatchError(
            "configuration_mode must be one of: "
            + ", ".join(sorted(CONFIGURATION_MODES))
        )
    if not isinstance(approval_policy, (str, dict)) or not approval_policy:
        raise DispatchError("approval_policy must be a non-empty string or object")
    if configuration_mode == "global-config":
        if permission_profile is not None:
            raise DispatchError("global-config verification cannot select a permission profile")
        if not isinstance(sandbox_mode, str):
            raise DispatchError("global-config verification requires sandbox_mode")
        _legacy_sandbox_receipt(sandbox_mode)
    else:
        if permission_profile is None:
            raise DispatchError("permission-profile verification requires permission_profile")
        if sandbox_mode is not None:
            raise DispatchError("permission-profile verification cannot select sandbox_mode")
    values.update(
        {
            "thread_id": thread_id,
            "configuration_mode": configuration_mode,
            "approval_policy": approval_policy,
            "sandbox_mode": sandbox_mode,
        }
    )
    return values


def bootstrap_worker_task(
    *,
    cwd: str,
    expected_runtime_project_id: str,
    title: str,
    model: str,
    thinking: str,
    permission_profile: Optional[str] = None,
    codex_executable: Optional[str] = None,
) -> Dict[str, Any]:
    values = _validated_inputs(cwd, title, model, thinking, permission_profile)
    values["expected_runtime_project_id"] = _validated_runtime_project_id(
        expected_runtime_project_id
    )
    executable = _resolve_codex_executable(codex_executable)
    with AppServerClient(executable) as client:
        config_result = client.request(
            "config/read", {"cwd": values["cwd"], "includeLayers": False}
        )
        config = config_result.get("config")
        if not isinstance(config, dict):
            raise DispatchError("config/read did not return effective config")
        selected_profile = values["permission_profile"] or config.get(
            "default_permissions", config.get("defaultPermissions")
        )
        sandbox_mode = config.get("sandbox_mode", config.get("sandboxMode"))
        approval_policy = config.get("approval_policy", config.get("approvalPolicy"))
        start_params: Dict[str, Any] = {
            "model": values["model"],
            "cwd": values["cwd"],
            "projectId": values["expected_runtime_project_id"],
            "config": {"model_reasoning_effort": values["thinking"]},
            "serviceName": "kepler",
        }

        if selected_profile is not None:
            if not isinstance(selected_profile, str) or not SAFE_IDENTIFIER.fullmatch(
                selected_profile
            ):
                raise DispatchError("effective default_permissions is not a valid profile id")
            profiles_result = client.request(
                "permissionProfile/list", {"cwd": values["cwd"]}
            )
            profiles = _allowed_profiles(profiles_result.get("data", []))
            if selected_profile not in profiles:
                raise DispatchError(
                    f"permission profile {selected_profile!r} is unavailable or disallowed for cwd"
                )
            start_params["permissions"] = selected_profile
            configuration_mode = "permission-profile"
        else:
            if values["permission_profile"] is not None:
                raise DispatchError("the requested permission profile could not be selected")
            if not isinstance(sandbox_mode, str) or approval_policy is None:
                raise DispatchError(
                    "effective config must provide either default_permissions or both "
                    "sandbox_mode and approval_policy"
                )
            configuration_mode = "global-config"

        start_result = client.request("thread/start", start_params)
        thread = start_result.get("thread")
        thread_id = thread.get("id") if isinstance(thread, dict) else None
        if not isinstance(thread_id, str) or not thread_id:
            raise DispatchError("thread/start did not return a thread id")
        actual_runtime_project_id = thread.get("projectId")
        if actual_runtime_project_id != values["expected_runtime_project_id"]:
            raise DispatchError(
                "thread/start projectId does not match expected_runtime_project_id"
            )
        client.request("thread/name/set", {"threadId": thread_id, "name": values["title"]})

        active_profile = start_result.get("activePermissionProfile")
        if configuration_mode == "permission-profile":
            if (
                not isinstance(active_profile, dict)
                or active_profile.get("id") != selected_profile
            ):
                raise DispatchError("thread/start did not apply the requested permission profile")
        else:
            sandbox = start_result.get("sandbox")
            if not isinstance(sandbox, dict) or sandbox.get("type") != _legacy_sandbox_receipt(
                sandbox_mode
            ):
                raise DispatchError("thread/start did not preserve the effective sandbox_mode")
            if start_result.get("approvalPolicy") != approval_policy:
                raise DispatchError("thread/start did not preserve the effective approval_policy")
            if active_profile is not None:
                raise DispatchError("thread/start unexpectedly selected a permission profile")
        return {
            "schemaVersion": "kepler.worker-task-bootstrap/v1",
            "threadId": thread_id,
            "expectedRuntimeProjectId": values["expected_runtime_project_id"],
            "actualRuntimeProjectId": actual_runtime_project_id,
            "cwd": start_result.get("cwd", values["cwd"]),
            "model": start_result.get("model", values["model"]),
            "thinking": start_result.get("reasoningEffort", values["thinking"]),
            "configurationMode": configuration_mode,
            "permissionProfile": selected_profile,
            "activePermissionProfile": active_profile,
            "sandboxMode": sandbox_mode,
            "approvalPolicy": start_result.get("approvalPolicy", approval_policy),
            "sandbox": start_result.get("sandbox"),
            "instructionSources": start_result.get("instructionSources", []),
            "empty": True,
        }


def verify_worker_task(
    *,
    thread_id: str,
    expected_runtime_project_id: str,
    cwd: str,
    model: str,
    thinking: str,
    configuration_mode: str,
    approval_policy: Any,
    permission_profile: Optional[str] = None,
    sandbox_mode: Optional[str] = None,
    require_empty: bool = True,
    codex_executable: Optional[str] = None,
) -> Dict[str, Any]:
    if not isinstance(require_empty, bool):
        raise DispatchError("require_empty must be a boolean")
    values = _validated_verification_inputs(
        thread_id=thread_id,
        expected_runtime_project_id=expected_runtime_project_id,
        cwd=cwd,
        model=model,
        thinking=thinking,
        configuration_mode=configuration_mode,
        approval_policy=approval_policy,
        permission_profile=permission_profile,
        sandbox_mode=sandbox_mode,
    )
    executable = _resolve_codex_executable(codex_executable)
    with AppServerClient(executable) as client:
        result = client.request("thread/resume", {"threadId": values["thread_id"]})

    thread = result.get("thread")
    if not isinstance(thread, dict) or thread.get("id") != values["thread_id"]:
        raise DispatchError("thread/resume did not return the exact worker task")
    actual_runtime_project_id = thread.get("projectId")
    if actual_runtime_project_id != values["expected_runtime_project_id"]:
        raise DispatchError(
            "thread/resume projectId does not match expected_runtime_project_id"
        )
    turns = thread.get("turns")
    if not isinstance(turns, list):
        raise DispatchError("thread/resume did not return the worker task turns")
    if require_empty and turns:
        raise DispatchError(
            "worker task is not empty; configuration must be verified before its prompt"
        )
    if not require_empty and not turns:
        raise DispatchError(
            "worker task is still empty; post-delivery verification requires a turn"
        )
    try:
        actual_cwd = str(Path(result.get("cwd", "")).expanduser().resolve(strict=True))
    except (OSError, RuntimeError):
        raise DispatchError("thread/resume did not return a resolvable cwd")
    if actual_cwd != values["cwd"]:
        raise DispatchError("thread/resume cwd does not match the exact worker path")
    if result.get("model") != values["model"]:
        raise DispatchError("thread/resume did not preserve the effective model")
    if result.get("reasoningEffort") != values["thinking"]:
        raise DispatchError("thread/resume did not preserve the effective reasoning level")
    if result.get("approvalPolicy") != values["approval_policy"]:
        raise DispatchError("thread/resume did not preserve the effective approval_policy")

    active_profile = result.get("activePermissionProfile")
    if values["configuration_mode"] == "permission-profile":
        if (
            not isinstance(active_profile, dict)
            or active_profile.get("id") != values["permission_profile"]
        ):
            raise DispatchError("thread/resume did not preserve the permission profile")
    else:
        if active_profile is not None:
            raise DispatchError("thread/resume unexpectedly selected a permission profile")
        sandbox = result.get("sandbox")
        if (
            not isinstance(sandbox, dict)
            or sandbox.get("type")
            != _legacy_sandbox_receipt(values["sandbox_mode"])
        ):
            raise DispatchError("thread/resume did not preserve the effective sandbox_mode")

    return {
        "schemaVersion": "kepler.worker-task-verification/v1",
        "verified": True,
        "threadId": values["thread_id"],
        "expectedRuntimeProjectId": values["expected_runtime_project_id"],
        "actualRuntimeProjectId": actual_runtime_project_id,
        "cwd": actual_cwd,
        "model": result.get("model"),
        "thinking": result.get("reasoningEffort"),
        "configurationMode": values["configuration_mode"],
        "permissionProfile": values["permission_profile"],
        "activePermissionProfile": active_profile,
        "sandboxMode": values["sandbox_mode"],
        "approvalPolicy": result.get("approvalPolicy"),
        "sandbox": result.get("sandbox"),
        "empty": not turns,
    }


def attach_herdr_worker(
    *,
    thread_id: str,
    expected_runtime_project_id: str,
    cwd: str,
    model: str,
    thinking: str,
    configuration_mode: str,
    approval_policy: Any,
    workspace_label: str,
    agent_name: str,
    permission_profile: Optional[str] = None,
    sandbox_mode: Optional[str] = None,
    codex_executable: Optional[str] = None,
    herdr_executable: Optional[str] = None,
) -> Dict[str, Any]:
    """Attach one Herdr Codex terminal to an already-empty exact worker task."""
    _require_herdr_environment()
    verification = verify_worker_task(
        thread_id=thread_id,
        expected_runtime_project_id=expected_runtime_project_id,
        cwd=cwd,
        model=model,
        thinking=thinking,
        configuration_mode=configuration_mode,
        approval_policy=approval_policy,
        permission_profile=permission_profile,
        sandbox_mode=sandbox_mode,
        require_empty=True,
        codex_executable=codex_executable,
    )
    label = _validated_herdr_label(workspace_label)
    name = _validated_herdr_agent_name(agent_name)
    executable = _resolve_herdr_executable(herdr_executable)
    herdr_capability = _verify_herdr_capability(executable)

    listed = _run_herdr(executable, ["agent", "list"])
    agents = listed.get("agents")
    if not isinstance(agents, list):
        raise DispatchError("Herdr agent/list did not return agents")
    if any(isinstance(agent, dict) and agent.get("name") == name for agent in agents):
        raise DispatchError("agent_name is already in use by a Herdr agent")

    created_workspace_id: Optional[str] = None
    try:
        created = _run_herdr(
            executable,
            ["workspace", "create", "--cwd", verification["cwd"], "--label", label, "--no-focus"],
        )
        workspace = created.get("workspace")
        tab = created.get("tab")
        root_pane = created.get("root_pane")
        if (
            created.get("type") != "workspace_created"
            or not isinstance(workspace, dict)
            or not isinstance(tab, dict)
            or not isinstance(root_pane, dict)
        ):
            raise DispatchError("Herdr workspace/create returned an invalid attachment")
        workspace_id = _validated_herdr_identifier(workspace.get("workspace_id"), "workspace_id")
        created_workspace_id = workspace_id
        tab_id = _validated_herdr_identifier(tab.get("tab_id"), "tab_id")
        pane_id = _validated_herdr_identifier(root_pane.get("pane_id"), "pane_id")
        if (
            tab.get("workspace_id") != workspace_id
            or root_pane.get("workspace_id") != workspace_id
            or root_pane.get("tab_id") != tab_id
        ):
            raise DispatchError("Herdr workspace/create identifiers are inconsistent")
        try:
            created_cwd = str(Path(root_pane.get("cwd", "")).expanduser().resolve(strict=True))
        except (OSError, RuntimeError):
            raise DispatchError("Herdr workspace/create did not return a resolvable cwd")
        if created_cwd != verification["cwd"]:
            raise DispatchError("Herdr workspace/create cwd does not match the exact worker path")
        _run_herdr(
            executable,
            [
                "agent",
                "start",
                name,
                "--kind",
                HERDR_AGENT_KIND,
                "--pane",
                pane_id,
                "--",
                "--no-alt-screen",
                "resume",
                verification["threadId"],
            ],
        )
        agent = _herdr_agent_info(executable, name)
        _validate_herdr_agent(
            agent,
            workspace_id=workspace_id,
            tab_id=tab_id,
            pane_id=pane_id,
            agent_name=name,
            worker_cwd=verification["cwd"],
            thread_id=verification["threadId"],
            require_terminal_state=False,
        )
    except Exception:
        if created_workspace_id is not None:
            try:
                _close_herdr_workspace(executable, created_workspace_id)
            except DispatchError:
                pass
        raise

    return {
        "schema_version": "kepler.herdr-attachment/v1",
        "herdr_version": herdr_capability["version"],
        "protocol": herdr_capability["protocol"],
        "workspace_id": workspace_id,
        "tab_id": tab_id,
        "pane_id": pane_id,
        "agent_name": name,
        "agent_kind": HERDR_AGENT_KIND,
        "resumed_task_id": verification["threadId"],
        "worker_cwd": verification["cwd"],
        "workspace_owned": True,
        "tab_owned": True,
        "pane_owned": True,
        "agent_owned": True,
    }


def _run_git(arguments: list[str], *, cwd: str, allow_exit_one: bool = False) -> subprocess.CompletedProcess[str]:
    try:
        completed = subprocess.run(
            ["git", *arguments],
            cwd=cwd,
            check=False,
            capture_output=True,
            text=True,
            timeout=DEFAULT_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise DispatchError(f"git command failed to run: {error}") from error
    if completed.returncode != 0 and not (allow_exit_one and completed.returncode == 1):
        diagnostic = completed.stderr.strip() or completed.stdout.strip()
        raise DispatchError(f"git command failed: {diagnostic or completed.returncode}")
    return completed


def _registered_linked_worktree(project_path: str, worker_cwd: str) -> bool:
    output = _run_git(["worktree", "list", "--porcelain"], cwd=project_path).stdout
    entries = [entry for entry in output.split("\n\n") if entry.strip()]
    for entry in entries:
        fields = dict(
            line.split(" ", 1) for line in entry.splitlines() if " " in line
        )
        raw_path = fields.get("worktree")
        if raw_path is None:
            continue
        try:
            candidate = str(Path(raw_path).expanduser().resolve(strict=True))
        except (OSError, RuntimeError):
            continue
        if candidate == worker_cwd:
            return candidate != project_path
    return False


def _worktree_safety_snapshot(project_path: str, worker_cwd: str) -> str:
    if not _registered_linked_worktree(project_path, worker_cwd):
        raise DispatchError("worker_cwd is not a registered non-primary worktree")
    if _run_git(["status", "--porcelain"], cwd=worker_cwd).stdout.strip():
        raise DispatchError("worker worktree is dirty")
    worker_head = _run_git(["rev-parse", "HEAD"], cwd=worker_cwd).stdout.strip()
    project_head = _run_git(["rev-parse", "HEAD"], cwd=project_path).stdout.strip()
    if not worker_head or not project_head:
        raise DispatchError("worker and project paths must have resolvable HEADs")
    ancestor = _run_git(
        ["merge-base", "--is-ancestor", worker_head, project_head],
        cwd=project_path,
        allow_exit_one=True,
    )
    if ancestor.returncode != 0:
        raise DispatchError("worker worktree HEAD is not merged into project_path HEAD")
    return worker_head


def _validate_cleanup_attachment(
    attachment: Any,
    *,
    thread_id: str,
    runtime_project_id: str,
    worker_cwd: str,
) -> Dict[str, Any]:
    if not isinstance(attachment, dict):
        raise DispatchError("herdr_attachment must be an object")
    allowed = {
        "schema_version",
        "herdr_version",
        "protocol",
        "workspace_id",
        "tab_id",
        "pane_id",
        "agent_name",
        "agent_kind",
        "resumed_task_id",
        "worker_cwd",
        "workspace_owned",
        "tab_owned",
        "pane_owned",
        "agent_owned",
    }
    unknown = set(attachment) - allowed
    if unknown:
        raise DispatchError(
            "herdr_attachment has unsupported fields: "
            + ", ".join(sorted(unknown))
        )
    required = {
        "schema_version": "kepler.herdr-attachment/v1",
        "resumed_task_id": thread_id,
        "worker_cwd": worker_cwd,
        "agent_kind": HERDR_AGENT_KIND,
        "workspace_owned": True,
        "tab_owned": True,
        "pane_owned": True,
        "agent_owned": True,
    }
    for key, expected in required.items():
        if attachment.get(key) != expected:
            raise DispatchError(f"herdr_attachment {key} does not match cleanup inputs")
    for key in ("workspace_id", "tab_id", "pane_id", "agent_name"):
        _validated_herdr_identifier(attachment.get(key), f"herdr_attachment.{key}")
    _validated_herdr_agent_name(attachment["agent_name"])
    if not isinstance(attachment.get("protocol"), int) or attachment["protocol"] < 19:
        raise DispatchError("herdr_attachment protocol must be at least 19")
    version = attachment.get("herdr_version")
    if not isinstance(version, str) or not version.strip():
        raise DispatchError("herdr_attachment herdr_version must be a non-empty string")
    return attachment


def cleanup_herdr_worker(
    *,
    thread_id: str,
    expected_runtime_project_id: str,
    project_path: str,
    worker_cwd: str,
    mode: str,
    herdr_attachment: Dict[str, Any],
    remove_worktree: bool,
    codex_executable: Optional[str] = None,
    herdr_executable: Optional[str] = None,
) -> Dict[str, Any]:
    """Close only an owned completed Herdr attachment and archive its exact task."""
    _require_herdr_environment()
    if mode not in WORKER_MODES:
        raise DispatchError("mode must be one of: " + ", ".join(sorted(WORKER_MODES)))
    if not isinstance(remove_worktree, bool):
        raise DispatchError("remove_worktree must be a boolean")
    if mode == "local" and remove_worktree:
        raise DispatchError("Local mode cannot remove a worktree")
    project = Path(project_path).expanduser().resolve()
    worker = Path(worker_cwd).expanduser().resolve()
    if not project.is_dir() or not worker.is_dir():
        raise DispatchError("project_path and worker_cwd must resolve to existing directories")
    project_value = str(project)
    worker_value = str(worker)
    runtime_project_id = _validated_runtime_project_id(expected_runtime_project_id)
    attachment = _validate_cleanup_attachment(
        herdr_attachment,
        thread_id=thread_id,
        runtime_project_id=runtime_project_id,
        worker_cwd=worker_value,
    )
    herdr = _resolve_herdr_executable(herdr_executable)
    codex = _resolve_codex_executable(codex_executable)
    herdr_capability = _verify_herdr_capability(herdr)

    agent = _herdr_agent_info(herdr, attachment["agent_name"])
    _validate_herdr_agent(
        agent,
        workspace_id=attachment["workspace_id"],
        tab_id=attachment["tab_id"],
        pane_id=attachment["pane_id"],
        agent_name=attachment["agent_name"],
        worker_cwd=worker_value,
        thread_id=thread_id,
        require_terminal_state=True,
    )
    with AppServerClient(codex) as client:
        resumed = client.request("thread/resume", {"threadId": thread_id})
    resumed_thread = resumed.get("thread")
    if not isinstance(resumed_thread, dict) or resumed_thread.get("id") != thread_id:
        raise DispatchError("thread/resume did not return the exact cleanup task")
    if resumed_thread.get("projectId") != runtime_project_id:
        raise DispatchError("thread/resume projectId does not match cleanup project")
    try:
        resumed_cwd = str(Path(resumed.get("cwd", "")).expanduser().resolve(strict=True))
    except (OSError, RuntimeError):
        raise DispatchError("thread/resume did not return a resolvable cleanup cwd")
    if resumed_cwd != worker_value:
        raise DispatchError("thread/resume cwd does not match cleanup worker path")
    status = resumed_thread.get("status")
    if not isinstance(status, dict) or status.get("type") != "idle":
        raise DispatchError("Codex worker is active or not idle")

    worker_head: Optional[str] = None
    if mode == "worktree" and remove_worktree:
        worker_head = _worktree_safety_snapshot(project_value, worker_value)

    _close_herdr_workspace(herdr, attachment["workspace_id"])
    with AppServerClient(codex) as client:
        client.request("thread/archive", {"threadId": thread_id})
    worktree_removed = False
    if mode == "worktree" and remove_worktree:
        final_worker_head = _worktree_safety_snapshot(project_value, worker_value)
        if final_worker_head != worker_head:
            raise DispatchError("worker worktree HEAD changed during cleanup")
        _run_git(["worktree", "remove", worker_value], cwd=project_value)
        worktree_removed = True
    return {
        "schemaVersion": "kepler.worker-cleanup/v1",
        "taskId": thread_id,
        "runtimeProjectId": runtime_project_id,
        "projectPath": project_value,
        "workerCwd": worker_value,
        "mode": mode,
        "herdrAttachment": attachment,
        "herdrWorkspaceClosed": True,
        "taskArchived": True,
        "removeWorktreeRequested": remove_worktree,
        "worktreeRemoved": worktree_removed,
        "branchPreserved": True,
    }


def bootstrap_planner_task(
    *,
    cwd: str,
    title: str,
    current_model: str,
    current_thinking: str,
    separate_task_requested: bool = False,
    expected_runtime_project_id: Optional[str] = None,
    permission_profile: Optional[str] = None,
    codex_executable: Optional[str] = None,
) -> Dict[str, Any]:
    if not isinstance(separate_task_requested, bool):
        raise DispatchError("separate_task_requested must be a boolean")
    current = _validated_inputs(
        cwd,
        title,
        current_model,
        current_thinking,
        permission_profile,
    )
    if (
        current["model"] == SOL_MODEL
        and current["thinking"] == SOL_THINKING
        and not separate_task_requested
    ):
        return {
            "schemaVersion": "kepler.planner-task-reuse/v1",
            "action": "reuse-current-task",
            "created": False,
            "cwd": current["cwd"],
            "model": current["model"],
            "thinking": current["thinking"],
            "role": "sol",
        }
    if expected_runtime_project_id is None:
        raise DispatchError(
            "expected_runtime_project_id is required when creating a separate planner task"
        )
    receipt = bootstrap_worker_task(
        cwd=cwd,
        expected_runtime_project_id=expected_runtime_project_id,
        title=title,
        model=SOL_MODEL,
        thinking=SOL_THINKING,
        permission_profile=permission_profile,
        codex_executable=codex_executable,
    )
    receipt["schemaVersion"] = "kepler.planner-task-bootstrap/v1"
    receipt["action"] = "created-separate-task"
    receipt["created"] = True
    receipt["role"] = "sol"
    return receipt


WORKER_TOOL = {
    "name": "bootstrap_worker_task",
    "description": (
        "Create one empty persistent local Codex worker task in an exact saved project "
        "while explicitly preserving the effective global config or named permission "
        "profile. The task is created with the expected opaque project ID and creation "
        "fails unless app-server returns that exact canonical project ID. This tool "
        "does not send a prompt, create a worktree, edit files, or monitor the task."
    ),
    "inputSchema": {
        "type": "object",
        "additionalProperties": False,
        "required": [
            "cwd",
            "expected_runtime_project_id",
            "title",
            "model",
            "thinking",
        ],
        "properties": {
            "cwd": {"type": "string", "description": "Exact saved-project path."},
            "expected_runtime_project_id": {
                "type": "string",
                "minLength": 1,
                "maxLength": 512,
                "description": "Opaque runtime ID of the exact owning saved project.",
            },
            "title": {"type": "string", "minLength": 1, "maxLength": 200},
            "model": {"type": "string", "minLength": 1},
            "thinking": {"type": "string", "enum": sorted(THINKING_LEVELS)},
            "permission_profile": {
                "type": "string",
                "description": (
                    "Optional named profile id. Omit to inherit the effective global "
                    "config for cwd, including legacy sandbox_mode and approval_policy."
                ),
            },
        },
    },
}

VERIFY_WORKER_TOOL = {
    "name": "verify_worker_task",
    "description": (
        "Fail-closed verification for an empty local or handed-off Worktree task. "
        "Call after bootstrap and any Worktree handoff, but before sending the worker "
        "prompt and again after prompt delivery or continuation. The tool resumes the "
        "exact task read-only and verifies its canonical project ID, path, model, "
        "reasoning, approval policy, sandbox or permission profile, and empty turn "
        "state when required. Any project mismatch fails closed."
    ),
    "inputSchema": {
        "type": "object",
        "additionalProperties": False,
        "required": [
            "thread_id",
            "expected_runtime_project_id",
            "cwd",
            "model",
            "thinking",
            "configuration_mode",
            "approval_policy",
        ],
        "properties": {
            "thread_id": {"type": "string", "minLength": 1},
            "expected_runtime_project_id": {
                "type": "string",
                "minLength": 1,
                "maxLength": 512,
            },
            "cwd": {"type": "string", "description": "Exact final worker path."},
            "model": {"type": "string", "minLength": 1},
            "thinking": {"type": "string", "enum": sorted(THINKING_LEVELS)},
            "configuration_mode": {
                "type": "string",
                "enum": sorted(CONFIGURATION_MODES),
            },
            "approval_policy": {
                "oneOf": [
                    {"type": "string", "minLength": 1},
                    {"type": "object", "minProperties": 1},
                ]
            },
            "permission_profile": {"type": "string", "minLength": 1},
            "sandbox_mode": {"type": "string", "minLength": 1},
            "require_empty": {
                "type": "boolean",
                "default": True,
                "description": (
                    "Require no turns before first prompt. Set false only for the "
                    "post-delivery or existing-task continuation check."
                ),
            },
        },
    },
}

PLANNER_TOOL = {
    "name": "bootstrap_planner_task",
    "description": (
        "Reuse the caller for Kepler planning when it already runs gpt-5.6-sol "
        "with high reasoning; otherwise create one empty persistent local Sol task "
        "with that exact runtime while preserving effective configuration. Set "
        "separate_task_requested only when the user explicitly asks for another "
        "planning task. This tool does not send a prompt, edit files, dispatch "
        "workers, or monitor a task."
    ),
    "inputSchema": {
        "type": "object",
        "additionalProperties": False,
        "required": ["cwd", "title", "current_model", "current_thinking"],
        "properties": {
            "cwd": {"type": "string", "description": "Exact Kepler control-project path."},
            "title": {"type": "string", "minLength": 1, "maxLength": 200},
            "current_model": {
                "type": "string",
                "minLength": 1,
                "description": "Effective model of the task calling this tool.",
            },
            "current_thinking": {
                "type": "string",
                "enum": sorted(THINKING_LEVELS),
                "description": "Effective reasoning level of the calling task.",
            },
            "separate_task_requested": {
                "type": "boolean",
                "default": False,
                "description": (
                    "True only when the user explicitly requested a separate Sol task."
                ),
            },
            "permission_profile": {
                "type": "string",
                "description": (
                    "Optional named profile id. Omit to inherit the effective global "
                    "config for cwd, including legacy sandbox_mode and approval_policy."
                ),
            },
            "expected_runtime_project_id": {
                "type": "string",
                "minLength": 1,
                "maxLength": 512,
                "description": (
                    "Required only when a separate planner task must be created."
                ),
            },
        },
    },
}

HERDR_ATTACHMENT_TOOL = {
    "name": "attach_herdr_worker",
    "description": (
        "Attach one Herdr-owned interactive Codex terminal to an already-empty exact "
        "worker task. The task remains the app-server worker; this tool starts only "
        "`codex --no-alt-screen resume <thread_id>` in a newly-created background "
        "Herdr workspace. It never sends a prompt or waits for worker completion."
    ),
    "inputSchema": {
        "type": "object",
        "additionalProperties": False,
        "required": [
            "thread_id",
            "expected_runtime_project_id",
            "cwd",
            "model",
            "thinking",
            "configuration_mode",
            "approval_policy",
            "workspace_label",
            "agent_name",
        ],
        "properties": {
            "thread_id": {"type": "string", "minLength": 1},
            "expected_runtime_project_id": {"type": "string", "minLength": 1, "maxLength": 512},
            "cwd": {"type": "string", "description": "Exact final worker path."},
            "model": {"type": "string", "minLength": 1},
            "thinking": {"type": "string", "enum": sorted(THINKING_LEVELS)},
            "configuration_mode": {"type": "string", "enum": sorted(CONFIGURATION_MODES)},
            "approval_policy": {"oneOf": [{"type": "string", "minLength": 1}, {"type": "object", "minProperties": 1}]},
            "permission_profile": {"type": "string", "minLength": 1},
            "sandbox_mode": {"type": "string", "minLength": 1},
            "workspace_label": {"type": "string", "minLength": 1, "maxLength": 120},
            "agent_name": {
                "type": "string",
                "pattern": "^[a-z][a-z0-9_-]{0,31}$",
            },
        },
    },
}

CLEANUP_HERDR_WORKER_TOOL = {
    "name": "cleanup_herdr_worker",
    "description": (
        "Fail-closed cleanup for one owned, idle or done Herdr worker attachment. "
        "The tool closes only the recorded workspace, archives only the exact Codex "
        "task, and removes a worktree only after clean registered-and-merged checks. "
        "Local mode never removes a path or branch."
    ),
    "inputSchema": {
        "type": "object",
        "additionalProperties": False,
        "required": [
            "thread_id",
            "expected_runtime_project_id",
            "project_path",
            "worker_cwd",
            "mode",
            "herdr_attachment",
            "remove_worktree",
        ],
        "properties": {
            "thread_id": {"type": "string", "minLength": 1},
            "expected_runtime_project_id": {"type": "string", "minLength": 1, "maxLength": 512},
            "project_path": {"type": "string", "description": "Primary repository path."},
            "worker_cwd": {"type": "string", "description": "Exact worker checkout path."},
            "mode": {"type": "string", "enum": sorted(WORKER_MODES)},
            "herdr_attachment": {"type": "object", "minProperties": 1},
            "remove_worktree": {"type": "boolean"},
        },
    },
}

TOOLS = (
    PLANNER_TOOL,
    WORKER_TOOL,
    VERIFY_WORKER_TOOL,
    HERDR_ATTACHMENT_TOOL,
    CLEANUP_HERDR_WORKER_TOOL,
)


def _mcp_result(payload: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "content": [{"type": "text", "text": json.dumps(payload, sort_keys=True)}],
        "structuredContent": payload,
        "isError": False,
    }


def _handle_request(message: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    request_id = message.get("id")
    method = message.get("method")
    if request_id is None:
        return None
    if method == "initialize":
        requested = message.get("params", {}).get("protocolVersion", "2025-06-18")
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": requested,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        }
    if method == "ping":
        return {"jsonrpc": "2.0", "id": request_id, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": request_id, "result": {"tools": list(TOOLS)}}
    if method == "tools/call":
        params = message.get("params")
        if not isinstance(params, dict):
            raise DispatchError("unknown tool")
        tool_name = params.get("name")
        arguments = params.get("arguments")
        if not isinstance(arguments, dict):
            raise DispatchError("tool arguments must be an object")
        if tool_name == WORKER_TOOL["name"]:
            allowed = {
                "cwd",
                "expected_runtime_project_id",
                "title",
                "model",
                "thinking",
                "permission_profile",
            }
            function = bootstrap_worker_task
        elif tool_name == VERIFY_WORKER_TOOL["name"]:
            allowed = {
                "thread_id",
                "expected_runtime_project_id",
                "cwd",
                "model",
                "thinking",
                "configuration_mode",
                "approval_policy",
                "permission_profile",
                "sandbox_mode",
                "require_empty",
            }
            function = verify_worker_task
        elif tool_name == PLANNER_TOOL["name"]:
            allowed = {
                "cwd",
                "title",
                "current_model",
                "current_thinking",
                "separate_task_requested",
                "expected_runtime_project_id",
                "permission_profile",
            }
            function = bootstrap_planner_task
        elif tool_name == HERDR_ATTACHMENT_TOOL["name"]:
            allowed = {
                "thread_id",
                "expected_runtime_project_id",
                "cwd",
                "model",
                "thinking",
                "configuration_mode",
                "approval_policy",
                "permission_profile",
                "sandbox_mode",
                "workspace_label",
                "agent_name",
            }
            function = attach_herdr_worker
        elif tool_name == CLEANUP_HERDR_WORKER_TOOL["name"]:
            allowed = {
                "thread_id",
                "expected_runtime_project_id",
                "project_path",
                "worker_cwd",
                "mode",
                "herdr_attachment",
                "remove_worktree",
            }
            function = cleanup_herdr_worker
        else:
            raise DispatchError("unknown tool")
        unexpected = set(arguments) - allowed
        if unexpected:
            raise DispatchError("unexpected tool arguments: " + ", ".join(sorted(unexpected)))
        result = function(**arguments)
        return {"jsonrpc": "2.0", "id": request_id, "result": _mcp_result(result)}
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": -32601, "message": f"method not found: {method}"},
    }


def serve() -> int:
    for line in sys.stdin:
        if not line.strip():
            continue
        request_id: Any = None
        try:
            message = json.loads(line)
            if not isinstance(message, dict):
                raise DispatchError("request must be a JSON object")
            request_id = message.get("id")
            response = _handle_request(message)
            if response is not None:
                _write_json(sys.stdout, response)
        except (DispatchError, TypeError, ValueError) as error:
            if request_id is not None:
                _write_json(
                    sys.stdout,
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "error": {"code": -32602, "message": str(error)},
                    },
                )
    return 0


if __name__ == "__main__":
    raise SystemExit(serve())
