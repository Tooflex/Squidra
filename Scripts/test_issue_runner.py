#!/usr/bin/env python3
"""Exercise runner process/report failures without needing a Swift toolchain."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

FAKE_SWIFT = '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
scenario = os.environ.get("SQUIDRA_RUNNER_FIXTURE", "pass")
if "list" in sys.argv:
    if scenario == "discovery_failure":
        sys.exit(13)
    print("SquidraDomainTests.ConfidenceTests/testBoundary")
    print("SquidraDomainTests.ConfidenceTests/testInvalid")
    sys.exit(0)
if scenario == "missing_report":
    sys.exit(0)
path = Path(sys.argv[sys.argv.index("--xunit-output") + 1])
if scenario == "malformed_report":
    path.write_text("not XML")
else:
    cases = '<testcase name="testBoundary"/><testcase name="testInvalid"/>'
    if scenario == "skipped":
        cases = '<testcase name="testBoundary"><skipped/></testcase><testcase name="testInvalid"><skipped/></testcase>'
    elif scenario == "partial":
        cases = '<testcase name="testBoundary"/>'
    elif scenario == "failed_case":
        cases = '<testcase name="testBoundary"><failure/></testcase><testcase name="testInvalid"/>'
    path.write_text('<testsuites><testsuite>' + cases + '</testsuite></testsuites>')
sys.exit(7 if scenario == "execution_failure" else 0)
'''


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / "Scripts"
        scripts.mkdir()
        source = Path(__file__).with_name("run-issue-tests.py")
        shutil.copy(source, scripts / source.name)
        (scripts / "issue-tests.json").write_text(json.dumps({
            "T01": {"kind": "xctest", "filter": r"^SquidraDomainTests\.ConfidenceTests/"}
        }))
        binary = self.root / "bin"
        binary.mkdir()
        swift = binary / "swift"
        swift.write_text(FAKE_SWIFT)
        swift.chmod(0o755)
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"])

    def run_fixture(self, scenario="pass", *args):
        return subprocess.run(
            [sys.executable, str(self.root / "Scripts/run-issue-tests.py"), "T01", *args],
            env=dict(self.env, SQUIDRA_RUNNER_FIXTURE=scenario), text=True, capture_output=True)

    def summary(self):
        return json.loads((self.root / ".build/issue-tests/T01/summary.json").read_text())

    def test_pass_requires_executed_cases(self):
        self.assertEqual(self.run_fixture().returncode, 0)
        self.assertEqual(self.summary()["passed"], 2)
        self.assertEqual(self.summary()["not_executed"], 0)

    def test_empty_selection_fails(self):
        self.assertEqual(self.run_fixture("pass", "--filter", "^Missing/").returncode, 1)
        self.assertEqual(self.summary()["status"], "empty_selection")

    def test_discovery_failure_preserves_exit_and_removes_stale_report(self):
        self.assertEqual(self.run_fixture().returncode, 0)
        self.assertEqual(self.run_fixture("discovery_failure").returncode, 13)
        self.assertFalse((self.root / ".build/issue-tests/T01/results.xml").exists())
        self.assertEqual(self.summary()["passed"], 0)

    def test_execution_failure_preserves_exit(self):
        self.assertEqual(self.run_fixture("execution_failure").returncode, 7)
        self.assertEqual(self.summary()["status"], "execution_failed")

    def test_missing_malformed_and_partial_reports_fail(self):
        for scenario in ["missing_report", "malformed_report", "partial"]:
            with self.subTest(scenario=scenario):
                self.assertNotEqual(self.run_fixture(scenario).returncode, 0)

    def test_fully_skipped_is_not_success(self):
        self.assertEqual(self.run_fixture("skipped").returncode, 1)
        self.assertEqual(self.summary()["skipped"], 2)
        self.assertEqual(self.summary()["passed"], 0)

    def test_reported_failure_fails_even_when_process_returns_zero(self):
        self.assertEqual(self.run_fixture("failed_case").returncode, 1)
        self.assertEqual(self.summary()["failed"], 1)

    def test_unknown_issue_fails(self):
        result = subprocess.run(
            [sys.executable, str(self.root / "Scripts/run-issue-tests.py"), "T99"],
            env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 2)

    def command_fixture(self, markers, code=0):
        command = self.root / "command.py"
        command.write_text("import sys\n" + "\n".join("print(" + repr(line) + ")" for line in markers)
                           + f"\nsys.exit({code})\n")
        manifest_path = self.root / "Scripts/issue-tests.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["T02"] = {"kind": "command", "command": [sys.executable, str(command)], "tests": ["first", "second"]}
        manifest_path.write_text(json.dumps(manifest))
        result = subprocess.run([sys.executable, str(self.root / "Scripts/run-issue-tests.py"), "T02"],
                                env=self.env, text=True, capture_output=True)
        summary = json.loads((self.root / ".build/issue-tests/T02/summary.json").read_text())
        return result.returncode, summary

    def test_command_suite_requires_all_real_assertion_markers(self):
        code, summary = self.command_fixture(["SQUIDRA_TEST_PASS:first", "SQUIDRA_TEST_PASS:second"])
        self.assertEqual(code, 0)
        self.assertEqual(summary["passed"], 2)

    def test_command_partial_report_cannot_pass(self):
        code, summary = self.command_fixture(["SQUIDRA_TEST_PASS:first"])
        self.assertEqual(code, 1)
        self.assertEqual(summary["not_executed"], 1)

    def test_command_duplicate_or_unknown_markers_fail(self):
        for markers in [["SQUIDRA_TEST_PASS:first"] * 2, ["SQUIDRA_TEST_PASS:other"]]:
            with self.subTest(markers=markers):
                code, summary = self.command_fixture(markers)
                self.assertEqual(code, 1)
                self.assertEqual(summary["status"], "invalid_report")

    def test_command_preserves_process_failure(self):
        code, summary = self.command_fixture(["SQUIDRA_TEST_PASS:first"], code=7)
        self.assertEqual(code, 7)
        self.assertEqual(summary["status"], "execution_failed")


if __name__ == "__main__":
    unittest.main()
