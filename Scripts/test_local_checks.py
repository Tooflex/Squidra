#!/usr/bin/env python3
"""Exercise local gate reporting without compiling Swift or starting Docker."""
import contextlib
import importlib.util
import io
import json
import re
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('local_checks', Path(__file__).with_name('check-local.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class LocalChecksTests(unittest.TestCase):
    def test_local_selection_matches_bootstrap(self):
        root = Path(__file__).resolve().parent.parent
        workflow = (root / '.github/workflows/bootstrap.yml').read_text()
        issues = re.findall(r'^        run: bash Scripts/test-issue.sh ([\w-]+)$', workflow, re.M)
        self.assertTrue(issues)
        self.assertEqual(json.loads((root / 'Scripts/local-checks.json').read_text()), issues)

    def exercise(self, args=(), fail=None, empty_status='empty_selection', change_lock=False,
                 non_database_command=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Scripts').mkdir()
            (root / 'Scripts/issue-tests.json').write_text(json.dumps({
                'T01': {'kind': 'xctest'}, 'T02': {'kind': 'command', 'requires_database': not non_database_command}}))
            (root / 'Scripts/local-checks.json').write_text('["T01", "T02"]')
            (root / 'Package.resolved').write_text('locked')
            commands = []

            def fake_run(command, **kwargs):
                commands.append(command)
                code = 0
                if '--filter' in command:
                    report = root / '.build/issue-tests/T01/summary.json'
                    report.parent.mkdir(parents=True)
                    report.write_text(json.dumps({'status': empty_status}))
                    code = 1
                elif fail and fail in command:
                    code = 7
                if change_lock and 'squidra' in command:
                    (root / 'Package.resolved').write_text('changed')
                return subprocess.CompletedProcess(command, code)

            with patch.object(gate, 'ROOT', root), patch.object(gate.subprocess, 'run', fake_run), \
                    patch('sys.argv', ['check-local.py', *args]), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                code = gate.main()
            report = json.loads(next(root.glob('.build/local-checks/*/summary.json')).read_text())
            return code, report, commands

    def test_full_gate(self):
        code, report, _ = self.exercise()
        self.assertEqual(code, 0)
        self.assertEqual(report['coverage'], 'full')
        self.assertEqual(report['not_executed'], [])
        self.assertEqual(report['omitted'], [])

    def test_partial_run_explicitly_omits_database(self):
        code, report, commands = self.exercise(['--unit-only'])
        self.assertEqual(code, 0)
        self.assertEqual(report['coverage'], 'unit-only')
        self.assertEqual(report['omitted'], ['T02'])
        self.assertFalse(any('Scripts/dev-db.sh' in c for c in commands))

    def test_failure_stops_and_reports_unexecuted_suites(self):
        code, report, _ = self.exercise(fail='Scripts/schema-manifest.py')
        self.assertEqual(code, 1)
        self.assertEqual(report['steps'][-1]['exit_code'], 7)
        self.assertEqual(report['not_executed'], ['T01', 'T02'])

    def test_non_database_commands_run_in_unit_mode(self):
        code, report, _ = self.exercise(['--unit-only'], non_database_command=True)
        self.assertEqual(code, 0)
        self.assertEqual(report['omitted'], [])
        self.assertIn('T02', [step['name'] for step in report['steps']])

    def test_integration_retry_explicitly_omits_unit_suites(self):
        code, report, commands = self.exercise(['--integration-only'])
        self.assertEqual(code, 0)
        self.assertEqual(report['coverage'], 'integration-only')
        self.assertEqual(report['omitted'], ['T01'])
        self.assertTrue(any('Scripts/dev-db.sh' in c for c in commands))

    def test_discovery_failure_is_not_an_expected_empty_selection(self):
        code, report, _ = self.exercise(empty_status='discovery_failed')
        self.assertEqual(code, 1)
        self.assertEqual(report['steps'][-1]['status'], 'failed')

    def test_lockfile_change_fails_gate(self):
        code, report, _ = self.exercise(change_lock=True)
        self.assertEqual(code, 1)
        self.assertIn('Package.resolved changed', report['error'])


if __name__ == '__main__':
    unittest.main()
