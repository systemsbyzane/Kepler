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
THINKING_LEVELS = {"low", "medium", "high", "xhigh", "max", "ultra"}
SAFE_IDENTIFIER = re.compile(r"^[A-Za-z0-9_.:+-]+$")
SOL_MODEL = "gpt-5.6-sol"
SOL_THINKING = "high"
CONFIGURATION_MODES = {"global-config", "permission-profile"}


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
    cwd: str,
    model: str,
    thinking: str,
    configuration_mode: str,
    approval_policy: Any,
    permission_profile: Optional[str],
    sandbox_mode: Optional[str],
) -> Dict[str, Any]:
    values = _validated_inputs(cwd, thread_id, model, thinking, permission_profile)
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
    title: str,
    model: str,
    thinking: str,
    permission_profile: Optional[str] = None,
    codex_executable: Optional[str] = None,
) -> Dict[str, Any]:
    values = _validated_inputs(cwd, title, model, thinking, permission_profile)
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
    cwd: str,
    model: str,
    thinking: str,
    configuration_mode: str,
    approval_policy: Any,
    permission_profile: Optional[str] = None,
    sandbox_mode: Optional[str] = None,
    codex_executable: Optional[str] = None,
) -> Dict[str, Any]:
    values = _validated_verification_inputs(
        thread_id=thread_id,
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
    turns = thread.get("turns")
    if not isinstance(turns, list) or turns:
        raise DispatchError(
            "worker task is not empty; configuration must be verified before its prompt"
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
        "cwd": actual_cwd,
        "model": result.get("model"),
        "thinking": result.get("reasoningEffort"),
        "configurationMode": values["configuration_mode"],
        "permissionProfile": values["permission_profile"],
        "activePermissionProfile": active_profile,
        "sandboxMode": values["sandbox_mode"],
        "approvalPolicy": result.get("approvalPolicy"),
        "sandbox": result.get("sandbox"),
        "empty": True,
    }


def bootstrap_planner_task(
    *,
    cwd: str,
    title: str,
    current_model: str,
    current_thinking: str,
    separate_task_requested: bool = False,
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
    receipt = bootstrap_worker_task(
        cwd=cwd,
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
        "Create one empty persistent local Codex worker task at an exact project path "
        "while explicitly preserving the effective global config or named permission "
        "profile. This tool "
        "does not send a prompt, create a worktree, edit files, or monitor the task."
    ),
    "inputSchema": {
        "type": "object",
        "additionalProperties": False,
        "required": ["cwd", "title", "model", "thinking"],
        "properties": {
            "cwd": {"type": "string", "description": "Exact saved-project path."},
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
        "prompt. The tool resumes the exact task read-only and verifies its path, model, "
        "reasoning, approval policy, sandbox or permission profile, and empty turn state."
    ),
    "inputSchema": {
        "type": "object",
        "additionalProperties": False,
        "required": [
            "thread_id",
            "cwd",
            "model",
            "thinking",
            "configuration_mode",
            "approval_policy",
        ],
        "properties": {
            "thread_id": {"type": "string", "minLength": 1},
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
        },
    },
}

TOOLS = (PLANNER_TOOL, WORKER_TOOL, VERIFY_WORKER_TOOL)


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
            allowed = {"cwd", "title", "model", "thinking", "permission_profile"}
            function = bootstrap_worker_task
        elif tool_name == VERIFY_WORKER_TOOL["name"]:
            allowed = {
                "thread_id",
                "cwd",
                "model",
                "thinking",
                "configuration_mode",
                "approval_policy",
                "permission_profile",
                "sandbox_mode",
            }
            function = verify_worker_task
        elif tool_name == PLANNER_TOOL["name"]:
            allowed = {
                "cwd",
                "title",
                "current_model",
                "current_thinking",
                "separate_task_requested",
                "permission_profile",
            }
            function = bootstrap_planner_task
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
