#!/usr/bin/env python3
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('metadata', Path(__file__).with_name('validate.py'))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


def sample():
    manifest = {'scope': 'used_names', 'tools': ['functions.exec']}
    return dict(issue=34, criteria=['Missing provenance fails; complete provenance passes.'], summary='Authored synthetic fixture, no personal data.', trace={'kind': 'local_record', 'id': 'fixture-record-034'}, tool_manifest=manifest, tool_hash=v.digest(manifest), usage={'models': 'unknown', 'tokens': 'unknown', 'cost': 'unknown'}, tests=['Authored fixture; not a production execution claim.'])


def body(data):
    return v.START + '\n' + json.dumps(data) + '\n' + v.END


class Tests(unittest.TestCase):
    def test_complete(self):
        self.assertEqual(v.validate(body(sample())), dict(status='passed', criteria_count=1, test_count=1))

    def test_missing_and_ambiguous(self):
        for value in ['', body(sample()) * 2, v.END + v.START, v.START + '{"issue":1,"issue":2}' + v.END]:
            with self.assertRaises(ValueError):
                v.validate(value)
        for field in sample():
            data = sample()
            del data[field]
            with self.assertRaises(ValueError):
                v.validate(body(data))

    def test_invalid_types_bounds_and_hash(self):
        for field, value in [('issue', True), ('criteria', []), ('tests', ['']), ('summary', 'TODO'), ('tool_hash', '0' * 64), ('usage', {'models': 'unknown'}), ('trace', {'kind': 'invented', 'id': 'abcdefgh'}), ('tool_manifest', {'scope': 'used_names', 'tools': ['z', 'a']})]:
            data = sample()
            data[field] = value
            with self.assertRaises(ValueError):
                v.validate(body(data))
        with self.assertRaises(ValueError):
            v.validate('x' * 65537)

    def test_redaction(self):
        for canary in ['MODEL_API_KEY=canary012345', 'Bearer canary012345', 'ghp_canary012345', 'password:canary012345', '-----BEGIN PRIVATE KEY-----\ncanary012345\n-----END PRIVATE KEY-----']:
            self.assertNotIn('canary012345', v.redact(canary))
            with self.assertRaises(ValueError):
                v.validate(body(sample()) + canary)

    def test_untrusted_text_never_executed(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / 'executed'
            data = sample()
            data['summary'] = f'$(touch {target}); `touch {target}`'
            v.validate(body(data))
            self.assertFalse(target.exists())

    def test_cli_sanitizes_parser_and_sensitive_failures(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'body'
            for value in [v.START + '{canary012345' + v.END, body(sample()) + 'MODEL_API_KEY=canary012345', body(sample())]:
                source.write_text(value)
                result = subprocess.run([sys.executable, str(Path(v.__file__)), '--body-file', str(source)], capture_output=True, text=True)
                self.assertNotIn('canary012345', result.stdout + result.stderr)
                self.assertEqual(result.returncode, 0 if value == body(sample()) else 1)

    def test_unknown_usage_and_manifest_scope_explicit(self):
        data = sample()
        data['tool_manifest']['scope'] = 'available_names'
        data['tool_hash'] = v.digest(data['tool_manifest'])
        v.validate(body(data))
        for field in ['models', 'tokens', 'cost']:
            changed = copy.deepcopy(data)
            changed['usage'][field] = ''
            with self.assertRaises(ValueError):
                v.validate(body(changed))


if __name__ == '__main__':
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests))
    if not result.wasSuccessful() or result.testsRun != 7:
        raise SystemExit(1)
    print('SQUIDRA_TEST_PASS:pr_provenance_contracts')
