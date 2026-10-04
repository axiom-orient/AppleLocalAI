"""Runner contract checks; these do not qualify native model inference."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts/verify-system-model.py"
SPEC = importlib.util.spec_from_file_location("system_model_runner", RUNNER)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class RunnerContractTests(unittest.TestCase):
    def test_existing_evidence_directory_is_not_modified(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "existing"
            output.mkdir()
            sentinel = output / "native-test.log"
            sentinel.write_bytes(b"original evidence\n")
            result = subprocess.run(
                [sys.executable, str(RUNNER), "--os", "26", "--simulator",
                 "B462783D-86CD-46ED-8C12-E147F20A65C1", "--developer-dir",
                 str(Path(directory) / "unused-xcode"), "--output", str(output),
                 "--check-only"], capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(sentinel.read_bytes(), b"original evidence\n")
            self.assertEqual(sorted(path.name for path in output.iterdir()), ["native-test.log"])

    def test_source_identity_keeps_consumers_separate(self):
        for version, (project, *_) in runner.CONSUMERS.items():
            with self.subTest(version=version):
                records = runner.source_identity(version, project)
                self.assertTrue(records)
                self.assertTrue(all(len(value) == 64 for value in records.values()))
                self.assertFalse(any(path.startswith("Backends/") for path in records))
                if version == 26:
                    self.assertIn("Compatibility/AppleLocalAISystem/Package.swift", records)
                    self.assertFalse(any(path.startswith("Sources/") for path in records))
                else:
                    self.assertIn("Package.swift", records)
                    self.assertFalse(any(path.startswith("Compatibility/") for path in records))

    def test_only_the_requested_test_result_is_collected(self):
        identifier = "nativeInference()"
        nodes = [{"children": [
            {"nodeType": "Test Case", "nodeIdentifier": "readiness()", "result": "Passed"},
            {"nodeType": "Test Case", "nodeIdentifier": identifier, "result": "Skipped"},
        ]}]
        self.assertEqual(runner.inference_results(nodes, identifier), ["Skipped"])
        self.assertEqual(runner.inference_results(nodes, "missing()"), [])


if __name__ == "__main__":
    unittest.main()
