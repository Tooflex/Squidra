#!/usr/bin/env python3
"""Read-only governance audit. A passing campaign profile is not full GH-033."""
import argparse
import base64
import json
from pathlib import Path
import subprocess

REPO = 'Tooflex/Squidra'
RULESET = 26267411
CHECKS = {'Swift 6.4.2 / ubuntu-24.04', 'Swift 6.4.2 / macos-15', 'PostgreSQL 17 / PostGIS + pgvector'}


def evaluate(data, profile):
    if profile not in {'strict', 'campaign-paused'}:
        raise ValueError('Unknown profile')
    repo, rule = data['repository'], data['ruleset']
    by_type = {}
    for entry in rule['rules']:
        kind = entry['type']
        if kind in by_type:
            raise ValueError('Duplicate rule')
        by_type[kind] = entry.get('parameters', {})
    pr = by_type.get('pull_request', {})
    conditions = rule.get('conditions', {}).get('ref_name', {})
    active_lines = [line.strip() for line in data['codeowners'].splitlines() if line.strip() and not line.lstrip().startswith('#')]
    results = {
        'repository_identity': repo['full_name'] == REPO and repo['default_branch'] == 'main',
        'auto_merge_disabled': repo.get('allow_auto_merge') is False,
        'ruleset_identity': rule.get('id') == RULESET and rule.get('source') == REPO and rule.get('target') == 'branch',
        'ruleset_active': rule.get('enforcement') == 'active',
        'default_branch_exact_scope': conditions == {'include': ['~DEFAULT_BRANCH'], 'exclude': []},
        'no_bypass': rule.get('bypass_actors') == [],
        'pull_request_required': 'pull_request' in by_type,
        'history_protected': 'deletion' in by_type and 'non_fast_forward' in by_type,
        'threads_resolved': pr.get('required_review_thread_resolution') is True,
        'codeowner_exact': active_lines == ['* @Tooflex'],
        'identified_administrator': data.get('administrator') == {'login': 'Tooflex', 'permission': 'admin'},
    }
    if profile == 'campaign-paused':
        results['authorized_review_profile'] = type(pr.get('required_approving_review_count')) is int and pr.get('required_approving_review_count') == 0 and pr.get('require_code_owner_review') is False
        results['required_checks_temporarily_absent'] = 'required_status_checks' not in by_type
    else:
        approvals = pr.get('required_approving_review_count')
        results['independent_review_required'] = type(approvals) is int and approvals >= 1 and pr.get('require_code_owner_review') is True and pr.get('require_last_push_approval') is True and pr.get('dismiss_stale_reviews_on_push') is True
        checks = by_type.get('required_status_checks', {})
        selected = checks.get('required_status_checks', [])
        results['strict_ci_required'] = checks.get('strict_required_status_checks_policy') is True and {x.get('context') for x in selected} == CHECKS and all(x.get('integration_id') == 15368 for x in selected)
    return {
        'profile': profile,
        'status': 'passed' if all(results.values()) else 'failed',
        'checks': results,
        'gh033_complete': False,
        'unverified': ['dedicated_minimum_privilege_app_token', 'test_repository_merge_without_review_rejected'],
    }


def api(path):
    result = subprocess.run(['gh', 'api', path], capture_output=True, timeout=30, check=True)
    if len(result.stdout) > 1_048_576:
        raise ValueError('Response too large')
    return json.loads(result.stdout)


def live():
    repository = api('repos/' + REPO)
    ruleset = api(f'repos/{REPO}/rulesets/{RULESET}')
    owner = api(f'repos/{REPO}/contents/.github/CODEOWNERS?ref=main')
    if owner.get('encoding') != 'base64' or owner.get('size', 1_048_577) > 65536:
        raise ValueError('Invalid CODEOWNERS')
    codeowners = base64.b64decode(owner['content']).decode('utf-8')
    administrator = api(f'repos/{REPO}/collaborators/Tooflex/permission')
    return {'repository': repository, 'ruleset': ruleset, 'codeowners': codeowners,
            'administrator': {'login': administrator['user']['login'], 'permission': administrator['permission']}}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', choices=['strict', 'campaign-paused'], default='strict')
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--live', action='store_true')
    source.add_argument('--fixture', type=Path)
    args = parser.parse_args()
    try:
        if args.live:
            data = live()
        else:
            with args.fixture.open('rb') as stream:
                raw = stream.read(1_048_577)
            if len(raw) > 1_048_576: raise ValueError('Fixture too large')
            data = json.loads(raw)
        report = evaluate(data, args.profile)
        report['evidence'] = 'live_read_only_api' if args.live else 'fixture_only'
        print(json.dumps(report, sort_keys=True))
        return 0 if report['status'] == 'passed' else 1
    except (ValueError, KeyError, TypeError, AttributeError, OSError, RecursionError, subprocess.SubprocessError):
        print('{"status":"failed","reason":"governance evidence unavailable or malformed"}')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
