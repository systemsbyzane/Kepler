#!/usr/bin/env python3
"""Run deterministic local Kepler acceptance probes."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


SCRIPTS = Path(__file__).resolve().parent
BOOTSTRAP = SCRIPTS / "bootstrap.py"
WORKLOADS = ("development", "charts", "patching", "research", "environments", "compliance")


def runtime_acceptance_placeholders() -> list[dict[str, str]]:
    return [
        {"name": "installed_project_first_setup_and_exact_identity", "status": "not_run_requires_installed_plugin_fresh_task"},
        {"name": "installed_sol_terra_model_binding", "status": "not_run_requires_installed_plugin_fresh_task"},
        {"name": "installed_worker_create_resume_result_and_no_monitoring", "status": "not_run_requires_installed_plugin_fresh_task"},
        {"name": "installed_plugin_upgrade_and_preservation_verification", "status": "not_run_requires_explicit_plugin_update_authorization"},
    ]


def run(arguments: list[str], *, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(arguments, cwd=cwd, text=True, capture_output=True, check=False, timeout=180)


def json_run(arguments: list[str], *, cwd: Path) -> dict[str, Any]:
    result = run(arguments, cwd=cwd)
    if result.returncode != 0:
        raise RuntimeError(f"command failed ({result.returncode}): {result.stderr or result.stdout}")
    value = json.loads(result.stdout)
    if not isinstance(value, dict):
        raise RuntimeError("command did not return a JSON object")
    return value


def probe(name: str, passed: bool, evidence: Any) -> dict[str, Any]:
    return {"name": name, "status": "passed" if passed else "failed", "evidence": evidence}


def run_harness() -> dict[str, Any]:
    probes: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="kepler-acceptance-") as directory:
        root = Path(directory)
        generated = root / "Kepler-Synthetic"
        preview = json_run([sys.executable, str(BOOTSTRAP), str(generated), "--json"], cwd=SCRIPTS)
        probes.append(probe(
            "bootstrap_preview_project_first",
            preview.get("status") == "preview" and not generated.exists() and preview.get("repository_scan_performed") is False,
            preview,
        ))
        applied = json_run([sys.executable, str(BOOTSTRAP), str(generated), "--apply", "--json"], cwd=SCRIPTS)
        probes.append(probe(
            "bootstrap_apply_validated",
            applied.get("status") == "generated_and_validated" and applied.get("validation", {}).get("doctor", {}).get("errors") == 0,
            applied,
        ))
        present = [name for name in WORKLOADS if (generated / name).exists()]
        probes.append(probe("no_default_workload_topology", not present, {"unexpected": present}))

        alpha = root / "alpha-project"
        beta = root / "beta-project"
        alpha.mkdir()
        beta.mkdir()
        initialized = run(["git", "init", "-q", str(alpha)], cwd=root)
        if initialized.returncode != 0:
            raise RuntimeError(initialized.stderr or "failed to initialize synthetic Git project")
        alpha_status_before = run(["git", "status", "--short"], cwd=alpha).stdout
        alpha_exclude = alpha / ".git" / "info" / "exclude"
        alpha_exclude_before = alpha_exclude.read_text(encoding="utf-8")
        catalog = root / "projects.json"
        catalog.write_text(json.dumps({"schemaVersion": 2, "projects": [
            {"projectId": "runtime-alpha-001", "projectKind": "local", "label": "Alpha", "path": str(alpha), "hostId": "local", "isGitRepository": True},
            {"projectId": "runtime-beta-002", "projectKind": "local", "label": "Beta", "path": str(beta), "hostId": "local", "isGitRepository": False},
        ]}), encoding="utf-8")
        command = str(generated / "bin" / "kepler")
        selection = ["--project-catalog", str(catalog), "--project-id", "runtime-alpha-001", "--project-id", "runtime-beta-002"]
        setup_plan = json_run([command, "setup", "plan", *selection, "--json"], cwd=generated)
        reviewed_architecture = setup_plan["architecture_map"]
        reviewed_architecture["workspaces"]["alpha"]["domains"]["api"] = {
            "paths": ["."],
            "facts": ["Synthetic user-confirmed API domain."],
        }
        reviewed_architecture_path = root / "reviewed-architecture.json"
        reviewed_architecture_path.write_text(json.dumps(reviewed_architecture), encoding="utf-8")
        setup_apply = json_run([
            command, "setup", "apply", *selection,
            "--architecture-map", str(reviewed_architecture_path), "--confirm", "--json",
        ], cwd=generated)
        setup_noop = json_run([
            command, "setup", "apply", *selection,
            "--architecture-map", str(reviewed_architecture_path), "--confirm", "--json",
        ], cwd=generated)
        alpha_status_after = run(["git", "status", "--short"], cwd=alpha).stdout
        alpha_exclude_after = alpha_exclude.read_text(encoding="utf-8")
        setup_ok = (
            setup_plan.get("repository_scan_performed") is False
            and setup_plan.get("selected_project_mutation") is False
            and setup_plan.get("bridges", {}).get("required") is False
            and setup_apply.get("status") == "configured"
            and setup_noop.get("changed") is False
            and setup_apply.get("architecture_map", {}).get("metadata", {}).get("confirmed") is True
            and "api" in setup_apply.get("architecture_map", {}).get("workspaces", {}).get("alpha", {}).get("domains", {})
            and alpha_status_before == alpha_status_after
            and alpha_exclude_before == alpha_exclude_after
            and not any(beta.iterdir())
        )
        probes.append(probe("project_first_setup_exact_identity", setup_ok, {
            "plan": setup_plan,
            "apply": setup_apply,
            "idempotent_rerun": setup_noop,
            "selected_project_git": {
                "status_before": alpha_status_before,
                "status_after": alpha_status_after,
                "info_exclude_unchanged": alpha_exclude_before == alpha_exclude_after,
            },
        }))
        route = json_run([
            command, "route", "plan", "--workspace", "alpha", "--domain", "root",
            "--work-type", "implementation", "--json",
        ], cwd=generated)
        route_ok = (
            route.get("runtime_project_id") == "runtime-alpha-001"
            and route.get("planner_runtime", {}).get("requested_model") == "gpt-5.6-sol"
            and route.get("dispatcher_runtime", {}).get("requested_model") == "gpt-5.6-terra"
            and route.get("bridge_handoff", {}).get("status") == "not_configured"
            and route.get("context_policy", {}).get("context_pack_is_exclusive_boundary") is False
            and route.get("context_policy", {}).get("transcript_sync") is False
        )
        probes.append(probe("model_bound_route_and_optional_bridge", route_ok, route))
        doctor = json_run([command, "doctor", "--json"], cwd=generated)
        probes.append(probe(
            "configured_doctor",
            doctor.get("summary", {}).get("errors") == 0 and doctor.get("summary", {}).get("selected_projects") == 2,
            doctor,
        ))

    locally_verified = all(item["status"] == "passed" for item in probes)
    return {
        "schema_version": "kepler.acceptance/v2",
        "locally_verified": locally_verified,
        "probes": probes,
        "runtime_acceptance": runtime_acceptance_placeholders(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    try:
        report = run_harness()
    except Exception as error:
        report = {
            "schema_version": "kepler.acceptance/v2",
            "locally_verified": False,
            "failure": str(error),
            "probes": [],
            "runtime_acceptance": runtime_acceptance_placeholders(),
        }
    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(payload, encoding="utf-8")
    print(payload, end="")
    return 0 if report.get("locally_verified") is True else 1


if __name__ == "__main__":
    raise SystemExit(main())
