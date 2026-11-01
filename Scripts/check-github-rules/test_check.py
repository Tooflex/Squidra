import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('check', Path(__file__).with_name('check.py'))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


def fixture():
    return {'repository': {'full_name': 'Tooflex/Squidra', 'default_branch': 'main', 'allow_auto_merge': False},
            'administrator': {'login': 'Tooflex', 'permission': 'admin'}, 'codeowners': '# Authored fixture\n* @Tooflex\n',
            'ruleset': {'id': 26267411, 'source': 'Tooflex/Squidra', 'target': 'branch', 'enforcement': 'active', 'bypass_actors': [],
                        'conditions': {'ref_name': {'include': ['~DEFAULT_BRANCH'], 'exclude': []}},
                        'rules': [{'type': 'deletion'}, {'type': 'non_fast_forward'}, {'type': 'pull_request', 'parameters': {'required_approving_review_count': 0, 'require_code_owner_review': False, 'required_review_thread_resolution': True}}]}}


class Tests(unittest.TestCase):
    def test_campaign_never_claims_full_issue(self):
        report = v.evaluate(fixture(), 'campaign-paused')
        self.assertEqual(report['status'], 'passed')
        self.assertFalse(report['gh033_complete'])
        self.assertEqual(len(report['unverified']), 2)

    def test_campaign_fails_strict(self):
        report = v.evaluate(fixture(), 'strict')
        self.assertEqual(report['status'], 'failed')
        self.assertFalse(report['checks']['independent_review_required'])
        self.assertFalse(report['checks']['strict_ci_required'])

    def test_strict_structure_passes_without_fabricating_app_evidence(self):
        data = fixture()
        data['ruleset']['rules'][-1]['parameters'].update(required_approving_review_count=1, require_code_owner_review=True, require_last_push_approval=True, dismiss_stale_reviews_on_push=True)
        data['ruleset']['rules'].append({'type': 'required_status_checks', 'parameters': {'strict_required_status_checks_policy': True, 'required_status_checks': [{'context': name, 'integration_id': 15368} for name in sorted(v.CHECKS)]}})
        report = v.evaluate(data, 'strict')
        self.assertEqual(report['status'], 'passed'); self.assertFalse(report['gh033_complete'])
        data['ruleset']['rules'][-1]['parameters']['required_status_checks'][0]['integration_id'] = 1
        self.assertEqual(v.evaluate(data, 'strict')['status'], 'failed')

    def test_bypass_exclusions_inactive_wrong_repository_fail(self):
        for field, value in [('bypass_actors', [{'actor_id': 1}]), ('enforcement', 'evaluate'), ('id', 1), ('source', 'other/repository'), ('conditions', {'ref_name': {'include': ['~DEFAULT_BRANCH'], 'exclude': ['refs/heads/main']}})]:
            data = fixture(); data['ruleset'][field] = value
            self.assertEqual(v.evaluate(data, 'campaign-paused')['status'], 'failed')
        data = fixture(); data['repository']['allow_auto_merge'] = True
        self.assertEqual(v.evaluate(data, 'campaign-paused')['status'], 'failed')

    def test_missing_rules_and_codeowner_override_fail(self):
        for index in range(3):
            data = fixture(); del data['ruleset']['rules'][index]
            self.assertEqual(v.evaluate(data, 'campaign-paused')['status'], 'failed')
        for value in ['', '* @Other', '* @Tooflex\nSources/** @Other']:
            data = fixture(); data['codeowners'] = value
            self.assertEqual(v.evaluate(data, 'campaign-paused')['status'], 'failed')
        data = fixture(); data['administrator']['permission'] = 'write'
        self.assertEqual(v.evaluate(data, 'campaign-paused')['status'], 'failed')

    def test_duplicate_rules_rejected(self):
        data = fixture(); data['ruleset']['rules'].append(copy.deepcopy(data['ruleset']['rules'][0]))
        with self.assertRaises(ValueError): v.evaluate(data, 'campaign-paused')

    def test_cli_fail_closed_without_echoing_content(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'fixture.json'
            for data in [fixture(), {'secret': 'CANARY_NEVER_ECHO_123'}]:
                path.write_text(json.dumps(data))
                result = subprocess.run([sys.executable, v.__file__, '--profile', 'campaign-paused', '--fixture', str(path)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0 if 'repository' in data else 1)
                self.assertNotIn('CANARY_NEVER_ECHO_123', result.stdout + result.stderr)


if __name__ == '__main__':
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests))
    if not result.wasSuccessful() or result.testsRun != 7: raise SystemExit(1)
    print('SQUIDRA_TEST_PASS:github_governance_contracts')
