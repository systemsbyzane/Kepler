#!/usr/bin/env python3
"""Reject stale Flightdeck product identifiers outside historical documentation."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


SKIP_PARTS = {".git", ".kepler-local", "__pycache__"}
TEXT_SUFFIXES = {
    "",
    ".json",
    ".md",
    ".py",
    ".rb",
    ".sh",
    ".txt",
    ".yaml",
    ".yml",
}
HISTORICAL_ALLOWLIST = {
    "CHANGELOG.md",
    "README.md",
    "docs/migration-from-flightdeck.md",
    "docs/upgrade.md",
    "plugins/kepler/releases.json",
    "plugins/kepler/skills/kepler-setup/scripts/compare_hubs.py",
    "plugins/kepler/skills/kepler-setup/scripts/scan_stale_names.py",
}
STALE_IDENTIFIER = re.compile(r"flightdeck", re.IGNORECASE)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path.cwd())
    args = parser.parse_args()
    root = args.root.resolve()
    findings: list[str] = []

    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        relative_name = relative.as_posix()
        if any(part in SKIP_PARTS for part in relative.parts):
            continue
        if (
            (path.is_file() or path.is_symlink())
            and STALE_IDENTIFIER.search(relative_name)
            and relative_name not in HISTORICAL_ALLOWLIST
        ):
            findings.append(f"stale path: {relative_name}")
        if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        if relative_name in HISTORICAL_ALLOWLIST:
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for line_number, line in enumerate(content.splitlines(), start=1):
            if STALE_IDENTIFIER.search(line):
                findings.append(f"stale identifier: {relative_name}:{line_number}")

    if findings:
        print("\n".join(findings))
        return 1
    print(
        "stale-name scan passed; Flightdeck identifiers are limited to "
        f"{len(HISTORICAL_ALLOWLIST)} historical files"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
