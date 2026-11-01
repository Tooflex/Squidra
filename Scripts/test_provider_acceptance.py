import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('provider_acceptance', Path(__file__).with_name('test-provider-acceptance.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ProviderAcceptanceTests(unittest.TestCase):
    def exercise(self, failure=None, summary_change=None, omit=False):
        calls = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def run(command, **kwargs):
                suite = command[-1]
                calls.append(suite)
                report = root / '.build/issue-tests' / suite / 'summary.json'
                report.parent.mkdir(parents=True, exist_ok=True)
                summary = dict(selected=2, passed=2, failed=0, skipped=0, not_executed=0, status='passed')
                summary.update(summary_change or {})
                if not omit:
                    report.write_text(json.dumps(summary))
                return subprocess.CompletedProcess(command, 7 if failure else 0, 'SQUIDRA_TEST_PASS:child_marker\n', '')
            # A stale success must not conceal a child which produces no report.
            report = root / '.build/issue-tests/T11-CONTRACTS/summary.json'
            report.parent.mkdir(parents=True)
            report.write_text(json.dumps(dict(selected=1, passed=1, failed=0, skipped=0, not_executed=0, status='passed')))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = gate.main('T11', root=root, run=run)
            return code, calls, output.getvalue()

    def test_every_child_must_pass_and_markers_do_not_leak(self):
        code, calls, output = self.exercise()
        self.assertEqual(code, 0)
        self.assertEqual(calls, gate.SUITES['T11'])
        self.assertNotIn('child_marker', output)
        self.assertEqual(output.count('SQUIDRA_TEST_PASS:'), len(calls))

    def test_failure_empty_skipped_partial_and_stale_reports_stop_the_gate(self):
        for kwargs in [dict(failure=True), dict(omit=True), dict(summary_change={'selected':0,'passed':0}),
                       dict(summary_change={'skipped':1}), dict(summary_change={'not_executed':1}),
                       dict(summary_change={'passed':1}), dict(summary_change={'status':'empty_selection'})]:
            code, calls, output = self.exercise(**kwargs)
            self.assertEqual(code, 7 if kwargs.get('failure') else 1)
            self.assertEqual(len(calls), 1)
            self.assertEqual(output, '')

    def test_paid_harnesses_are_not_in_offline_issue_gates(self):
        self.assertEqual(gate.main('unknown'), 2)
        manifest = json.loads((gate.ROOT / 'Scripts/issue-tests.json').read_text())
        for issue, suites in gate.SUITES.items():
            self.assertEqual(manifest[issue]['tests'], [gate.marker(s) for s in suites])
            for suite in suites:
                self.assertIn(suite, manifest)
                self.assertNotIn('test-meta-question-live', str(manifest[suite]))
                self.assertNotIn('test-meta-live', str(manifest[suite]))
