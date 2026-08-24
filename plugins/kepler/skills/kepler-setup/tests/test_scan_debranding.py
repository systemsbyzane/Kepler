#!/usr/bin/env python3
"""Focused tests for applied-control-project de-branding boundaries."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from scan_debranding import declared_selected_project_paths, scan  # noqa: E402


class DebrandingRuntimePathTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="kepler-debranding-")
        self.root = Path(self.tempdir.name) / "Kepler-Synthetic"
        (self.root / "hub").mkdir(parents=True)
        self.selected = Path.home() / "synthetic-company" / "project-alpha"
        (self.root / "hub" / "architecture-map.yaml").write_text(
            "\n".join(
                [
                    "api_version: kepler.dev/v1",
                    "kind: ArchitectureMap",
                    "metadata:",
                    "  confirmed: true",
                    "workspaces:",
                    "  project-alpha:",
                    f'    project_path: "{self.selected}"',
                ]
            )
            + "\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def findings(self, text: str) -> list[tuple[str, int, str, str]]:
        (self.root / "hub" / "state.yaml").write_text(text, encoding="utf-8")
        allowed = (str(self.root), *declared_selected_project_paths(self.root))
        return scan(
            self.root,
            set(),
            allowed_exact_paths=allowed,
            generated_control_plane_only=True,
        )

    def test_confirmed_selected_project_path_is_allowed_exactly(self) -> None:
        self.assertEqual(
            (str(self.selected),), declared_selected_project_paths(self.root)
        )
        self.assertEqual([], self.findings(f'project_path: "{self.selected}"\n'))

    def test_undeclared_or_prefixed_home_path_still_fails(self) -> None:
        rogue = Path.home() / "synthetic-company" / "rogue"
        findings = self.findings(
            f'rogue: "{rogue}"\nprefixed: "{self.selected}-copy"\n'
        )
        self.assertEqual(2, len(findings))
        self.assertTrue(all(item[2] == "current-home-path" for item in findings))


if __name__ == "__main__":
    unittest.main()
