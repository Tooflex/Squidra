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


spec_app = importlib.util.spec_from_file_location('app_job', Path(__file__).with_name('app_job.py'))
a = importlib.util.module_from_spec(spec_app)
spec_app.loader.exec_module(a)
from datetime import datetime, timezone, timedelta


class AppTests(unittest.TestCase):
    def fake(self, permissions=None, repositories=None):
        self.calls = []
        def call(method, path, credential, body=None):
            self.calls.append((method, path, body))
            if path == '/app': return {'id': a.APP, 'slug': 'tooflex-squidra-bot'}
            if path.endswith('/access_tokens'):
                return {'token': 'CANARY_NEVER_ECHO_123', 'permissions': a.PERMISSIONS if permissions is None else permissions,
                        'expires_at': (datetime.now(timezone.utc) + timedelta(minutes=59)).isoformat()}
            if path == '/installation/repositories':
                names = repositories or ['Tooflex/Squidra']
                return {'total_count': len(names), 'repositories': [{'full_name': n} for n in names]}
            if path.startswith('/app/installations/'):
                return {'app_id': a.APP, 'account': {'login': 'Tooflex'}, 'repository_selection': 'selected', 'permissions': a.PERMISSIONS}
        return call

    def test_scoped_job_revokes_after_success(self):
        with a.installation_job('Tooflex/Squidra', None, self.fake(), lambda _: 'fixture') as request:
            request('GET', '/branches/main')
        self.assertEqual(self.calls[-1][:2], ('DELETE', '/installation/token'))
        issuance = [x for x in self.calls if x[0] == 'POST'][0]
        self.assertEqual(issuance[2]['repositories'], ['Squidra'])

    def test_revokes_after_job_failure(self):
        with self.assertRaises(RuntimeError):
            with a.installation_job('Tooflex/Squidra', None, self.fake(), lambda _: 'fixture'):
                raise RuntimeError('job failed')
        self.assertEqual(self.calls[-1][0], 'DELETE')

    def test_broad_grant_revoked_before_job(self):
        for permissions, repos in [({'administration': 'write'}, None), (None, ['Tooflex/Squidra', 'Tooflex/Other'])]:
            with self.assertRaises(ValueError):
                with a.installation_job('Tooflex/Squidra', None, self.fake(permissions, repos), lambda _: 'fixture'):
                    self.fail('unverified grant reached job')
            self.assertEqual(self.calls[-1][0], 'DELETE')

    def test_invalid_repository_rejected_before_signing(self):
        with self.assertRaises(ValueError):
            with a.installation_job('Tooflex/Other', None, self.fake(), lambda _: self.fail('signed')):
                self.fail('job ran')

    def test_invalid_expiry_rejected(self):
        now = datetime.now(timezone.utc)
        for seconds in [-1, 30, 4000]:
            with self.assertRaises(ValueError):
                a.validate_grant({'permissions': a.PERMISSIONS, 'expires_at': (now + timedelta(seconds=seconds)).isoformat()}, now)

    def test_merge_rejects_wrong_branch_or_head_before_write(self):
        for branch, sha in [('main', 'a'*40), ('bot/33-fixture', 'b'*40)]:
            calls = []
            def request(method, path, body=None):
                calls.append(method)
                return {'head': {'repo': {'full_name': 'Tooflex/Squidra'}, 'ref': branch, 'sha': sha}, 'base': {'ref': 'main'}, 'draft': False}
            with self.assertRaises(ValueError): a.merge(request, 'Tooflex/Squidra', 1, 'a'*40)
            self.assertEqual(calls, ['GET'])

    def test_insecure_key_rejected_before_openssl(self):
        with tempfile.TemporaryDirectory() as folder:
            key = Path(folder) / 'key'
            key.write_text('not a real key')
            key.chmod(0o644)
            with self.assertRaises(ValueError): a.jwt(key)
            link = Path(folder) / 'link'
            link.symlink_to(key)
            with self.assertRaises(ValueError): a.jwt(link)

    def test_redirect_never_forwards_credential(self):
        with self.assertRaises(ValueError):
            a.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other.invalid')

    def test_exact_merge_sha_and_safe_routes(self):
        calls = []
        def request(method, path, body=None):
            calls.append((method, body))
            return {'head': {'repo': {'full_name': 'Tooflex/Squidra'}, 'ref': 'bot/33-fixture', 'sha': 'a'*40}, 'base': {'ref': 'main'}, 'draft': False}
        a.merge(request, 'Tooflex/Squidra', 1, 'a'*40)
        self.assertEqual(calls[-1], ('PUT', {'sha': 'a'*40, 'merge_method': 'merge'}))
        with a.installation_job('Tooflex/Squidra', None, self.fake(), lambda _: 'fixture') as request:
            with self.assertRaises(ValueError): request('GET', '/../Other')


if __name__ == '__main__':
    suite = unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(c) for c in (Tests, AppTests)])
    result = unittest.TextTestRunner().run(suite)
    if not result.wasSuccessful() or result.testsRun != 16: raise SystemExit(1)
    print('SQUIDRA_TEST_PASS:github_governance_contracts')
