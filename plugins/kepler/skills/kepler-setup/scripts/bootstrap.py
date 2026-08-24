#!/usr/bin/env python3
"""Preview, generate, or validate a Kepler control project."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
TEMPLATE = ROOT / "assets" / "kepler-template"
REPOSITORY_ROOT = ROOT.parents[3]
PREFLIGHT = SCRIPTS / "preflight.py"
SETUP = SCRIPTS / "setup_kepler.py"
STRUCTURED = SCRIPTS / "validate_structured.py"
SCANNER = SCRIPTS / "scan_debranding.py"
LINKS = SCRIPTS / "validate_links.py"
CONFIGURABLE = {Path("kepler.yaml"), Path("hub/repositories.yaml")}
RUBY_SUMMARY = re.compile(
    r"(?P<runs>\d+) runs, (?P<assertions>\d+) assertions, "
    r"(?P<failures>\d+) failures, (?P<errors>\d+) errors, "
    r"(?P<skips>\d+) skips"
)


class Failure(RuntimeError):
    def __init__(self, stage: str, message: str, code: int = 1) -> None:
        super().__init__(message)
        self.stage = stage
        self.code = code


def command(
    arguments: list[str],
    *,
    cwd: Path,
    stage: str,
    allowed: tuple[int, ...] = (0,),
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            arguments,
            cwd=cwd,
            text=True,
            capture_output=True,
            check=False,
            timeout=300,
            env={**os.environ, "LC_ALL": "C"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Failure(stage, f"command could not complete: {error}") from error
    if result.returncode not in allowed:
        detail = (result.stderr or result.stdout).strip()
        raise Failure(stage, f"command exited {result.returncode}: {detail}")
    return result


def json_command(arguments: list[str], *, cwd: Path, stage: str) -> dict[str, Any]:
    result = command(arguments, cwd=cwd, stage=stage)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise Failure(stage, f"command returned invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise Failure(stage, "command returned a non-object JSON value")
    return value


def normalize_target(requested: Path) -> Path:
    expanded = requested.expanduser()
    if expanded.is_symlink():
        raise Failure("target", f"target must not be a symlink: {expanded}", 2)
    target = expanded.resolve(strict=False)
    if target == Path(target.anchor) or target == Path.home().resolve():
        raise Failure("target", f"unsafe target path: {target}", 2)
    if target.exists() and not target.is_dir():
        raise Failure("target", f"target must be absent or a directory: {target}", 2)
    try:
        relative = target.relative_to(REPOSITORY_ROOT.resolve())
    except ValueError:
        pass
    else:
        if not relative.parts or relative.parts[0] != ".kepler-local":
            raise Failure("target", f"target must be outside the Kepler plugin source: {target}", 2)
    return target


def preflight() -> dict[str, Any]:
    report = json_command(
        [sys.executable, str(PREFLIGHT), "--json"],
        cwd=SCRIPTS,
        stage="preflight",
    )
    commands = report.get("commands")
    if report.get("local_ready") is not True or not isinstance(commands, dict):
        raise Failure("preflight", "python3, ruby, and git are required")
    return report


def managed_files() -> list[Path]:
    return sorted(path for path in TEMPLATE.rglob("*") if path.is_file())


def expected_bytes(source: Path, target: Path) -> bytes:
    content = source.read_bytes()
    if source.relative_to(TEMPLATE) == Path("kepler.yaml"):
        escaped = json.dumps(str(target), ensure_ascii=False)[1:-1].encode()
        content = content.replace(b"__KEPLER_ROOT__", escaped)
    return content


def parse_yaml(path: Path, ruby: str) -> dict[str, Any]:
    script = (
        "value=YAML.safe_load(File.read(ARGV.fetch(0)),"
        " permitted_classes:[Date,Time], permitted_symbols:[], aliases:false);"
        "puts JSON.generate(value)"
    )
    return json_command(
        [ruby, "-rjson", "-ryaml", "-rdate", "-e", script, str(path)],
        cwd=path.parent,
        stage="target-recognition",
    )


def recognize(target: Path, ruby: str) -> None:
    required = (
        target / "kepler.yaml",
        target / "hub" / "state" / "repositories.yaml",
        target / "hub" / "state" / "projects.yaml",
    )
    missing = [str(path.relative_to(target)) for path in required if not path.is_file()]
    if missing:
        raise Failure(
            "target-recognition",
            "non-empty target is not a complete generated Kepler; missing: "
            + ", ".join(missing),
            2,
        )
    mismatches: list[str] = []
    for source in managed_files():
        relative = source.relative_to(TEMPLATE)
        if relative in CONFIGURABLE:
            continue
        candidate = target / relative
        if not candidate.is_file() or candidate.read_bytes() != expected_bytes(source, target):
            mismatches.append(str(relative))
    if mismatches:
        raise Failure(
            "target-recognition",
            "non-empty target has unrecognized generated managed content: "
            + ", ".join(mismatches),
            2,
        )
    registry = parse_yaml(target / "kepler.yaml", ruby)
    if (
        registry.get("api_version") != "kepler.dev/v1alpha1"
        or registry.get("kind") != "KeplerRegistry"
        or registry.get("workspace", {}).get("root") != str(target)
        or registry.get("codex_projects", {}).get("kepler", {}).get("path") != str(target)
    ):
        raise Failure("target-recognition", "generated Kepler exact root identity does not match", 2)


def validate(target: Path, python3: str, ruby: str) -> dict[str, Any]:
    tests = command(
        [ruby, "-Ilib", "tests/kepler_test.rb"],
        cwd=target,
        stage="ruby-tests",
    )
    match = RUBY_SUMMARY.search(tests.stdout)
    if not match:
        raise Failure("ruby-tests", "Minitest summary was not found")
    ruby_counts = {key: int(value) for key, value in match.groupdict().items()}
    structured = json_command(
        [python3, str(STRUCTURED), str(target), "--json"],
        cwd=SCRIPTS,
        stage="structured-validation",
    )
    doctor = json_command(
        [str(target / "bin" / "kepler"), "doctor", "--json"],
        cwd=target,
        stage="doctor",
    )
    if doctor.get("summary", {}).get("errors") != 0:
        raise Failure("doctor", "Doctor reported errors")
    debranding = command(
        [python3, str(SCANNER), str(target), "--allow-generated-root"],
        cwd=SCRIPTS,
        stage="debranding",
    )
    links = command([python3, str(LINKS)], cwd=SCRIPTS, stage="setup-links")
    findings = re.search(r"(\d+) finding\(s\)", debranding.stdout)
    link_counts = re.search(
        r"(?P<required>\d+) required path\(s\), (?P<failures>\d+) failure\(s\)",
        links.stdout,
    )
    if not findings or not link_counts:
        raise Failure("validation", "validation summary counts were not found")
    return {
        "ruby_tests": ruby_counts,
        "structured": {
            **structured.get("counts", {}),
            "failures": len(structured.get("failures", [])),
        },
        "doctor": doctor["summary"],
        "debranding": {"findings": int(findings.group(1))},
        "setup_links": {key: int(value) for key, value in link_counts.groupdict().items()},
    }


def bootstrap(target: Path, *, apply: bool) -> dict[str, Any]:
    preflight_report = preflight()
    python3 = str(preflight_report["commands"]["python3"]["path"])
    ruby = str(preflight_report["commands"]["ruby"]["path"])
    report: dict[str, Any] = {
        "schema_version": "kepler.bootstrap/v2",
        "target": str(target),
        "mode": "apply" if apply else "preview",
        "status": "pending",
        "generated": False,
        "no_op": False,
        "project_first": True,
        "repository_scan_performed": False,
        "workload_directories_created": False,
        "bridges_installed": False,
        "runtime_status": "installed_fresh_task_acceptance_required",
        "preflight": {
            name: preflight_report["commands"][name]
            for name in ("python3", "ruby", "git")
        },
    }
    state = "absent" if not target.exists() else ("empty" if not any(target.iterdir()) else "generated")
    if state == "generated":
        recognize(target, ruby)
        report["validation"] = validate(target, python3, ruby)
        report["status"] = "validated_noop"
        report["no_op"] = True
        return report
    if not apply:
        report["status"] = "preview"
        report["would_generate"] = True
        return report
    setup = json_command(
        [python3, str(SETUP), str(target), "--json"],
        cwd=SCRIPTS,
        stage="generation",
    )
    if setup.get("generated") is not True:
        raise Failure("generation", "setup helper did not confirm generation")
    report["generated"] = True
    recognize(target, ruby)
    report["validation"] = validate(target, python3, ruby)
    report["status"] = "generated_and_validated"
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target_path", nargs="?", type=Path)
    parser.add_argument("--target", dest="target_option", type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.target_path and args.target_option:
        parser.error("provide target positionally or with --target, not both")
    requested = args.target_option or args.target_path
    if requested is None:
        parser.error("a target is required")
    target: Path | None = None
    try:
        target = normalize_target(requested)
        report = bootstrap(target, apply=args.apply)
    except Failure as error:
        report = {
            "schema_version": "kepler.bootstrap/v2",
            "target": str(target or requested.expanduser()),
            "mode": "apply" if args.apply else "preview",
            "status": "failed",
            "error": {"stage": error.stage, "message": str(error)},
        }
        if args.json:
            print(json.dumps(report, indent=2, sort_keys=True))
        else:
            print(f"Bootstrap failed during {error.stage}: {error}", file=sys.stderr)
        return error.code
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"{report['status']}: {report['target']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
