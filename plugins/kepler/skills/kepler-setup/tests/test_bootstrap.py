#!/usr/bin/env python3
"""Focused tests for project-first Kepler bootstrap."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
BOOTSTRAP = ROOT / "scripts" / "bootstrap.py"
TEMPLATE = ROOT / "assets" / "kepler-template"
WORKLOADS = ("development", "charts", "patching", "research", "environments", "compliance")


class BootstrapTest(unittest.TestCase):
    def run_bootstrap(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(BOOTSTRAP), *arguments],
            cwd=ROOT,
            check=False,
            text=True,
            capture_output=True,
            timeout=180,
        )

    def report(self, result: subprocess.CompletedProcess[str]) -> dict:
        self.assertTrue(result.stdout, result.stderr)
        return json.loads(result.stdout)

    def test_template_contains_no_workload_directories(self) -> None:
        for name in WORKLOADS:
            self.assertFalse((TEMPLATE / name).exists(), name)

    def test_preview_is_read_only_and_project_first(self) -> None:
        with tempfile.TemporaryDirectory(prefix="kepler-preview-") as directory:
            target = Path(directory) / "Kepler-Synthetic"
            result = self.run_bootstrap(str(target), "--json")
            self.assertEqual(0, result.returncode, result.stderr)
            report = self.report(result)
            self.assertEqual("preview", report["status"])
            self.assertTrue(report["project_first"])
            self.assertFalse(report["repository_scan_performed"])
            self.assertFalse(report["bridges_installed"])
            self.assertFalse(target.exists())

    def test_apply_generates_validates_and_reruns_as_noop(self) -> None:
        with tempfile.TemporaryDirectory(prefix="kepler-apply-") as directory:
            target = Path(directory) / "Kepler-Synthetic"
            first = self.run_bootstrap(str(target), "--apply", "--json")
            self.assertEqual(0, first.returncode, first.stdout + first.stderr)
            report = self.report(first)
            self.assertEqual("generated_and_validated", report["status"])
            self.assertEqual(0, report["validation"]["ruby_tests"]["failures"])
            self.assertEqual(0, report["validation"]["doctor"]["errors"])
            for name in WORKLOADS:
                self.assertFalse((target / name).exists(), name)

            second = self.run_bootstrap(str(target), "--apply", "--json")
            self.assertEqual(0, second.returncode, second.stdout + second.stderr)
            self.assertEqual("validated_noop", self.report(second)["status"])

    def test_repositories_root_option_is_removed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="kepler-no-scan-") as directory:
            result = self.run_bootstrap(
                str(Path(directory) / "Kepler-Synthetic"),
                "--repositories-root",
                directory,
                "--json",
            )
            self.assertEqual(2, result.returncode)
            self.assertIn("unrecognized arguments", result.stderr)

    def test_refuses_home_root_symlink_and_partial_targets(self) -> None:
        with tempfile.TemporaryDirectory(prefix="kepler-refusal-") as directory:
            root = Path(directory)
            real = root / "real"
            real.mkdir()
            link = root / "link"
            link.symlink_to(real, target_is_directory=True)
            linked = self.run_bootstrap(str(link), "--json")
            self.assertEqual(2, linked.returncode)
            self.assertEqual("target", self.report(linked)["error"]["stage"])

            partial = root / "partial"
            partial.mkdir()
            (partial / "kepler.yaml").write_text("kind: KeplerRegistry\n", encoding="utf-8")
            incomplete = self.run_bootstrap(str(partial), "--json")
            self.assertEqual(2, incomplete.returncode)
            self.assertEqual("target-recognition", self.report(incomplete)["error"]["stage"])

        for unsafe in (Path("/"), Path.home()):
            result = self.run_bootstrap(str(unsafe), "--json")
            self.assertEqual(2, result.returncode)


if __name__ == "__main__":
    unittest.main()
