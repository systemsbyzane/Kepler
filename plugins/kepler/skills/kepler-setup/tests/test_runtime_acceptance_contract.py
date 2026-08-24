from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))


def load_script(name: str):
    path = SCRIPTS / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ACCEPTANCE_HARNESS = load_script("acceptance_harness")
COMPARE_HUBS = load_script("compare_hubs")


class RuntimeAcceptanceContractTest(unittest.TestCase):
    def test_harness_and_semantic_parity_use_the_same_runtime_assertions(self) -> None:
        placeholders = ACCEPTANCE_HARNESS.runtime_acceptance_placeholders()
        installed = {
            item["name"]
            for item in placeholders
            if item["name"]
            != "installed_plugin_upgrade_and_preservation_verification"
        }
        self.assertEqual(
            COMPARE_HUBS.REQUIRED_RUNTIME_ACCEPTANCE_NAMES,
            installed,
        )
        self.assertIn(
            "installed_worker_create_resume_result_and_no_monitoring",
            installed,
        )


if __name__ == "__main__":
    unittest.main()
