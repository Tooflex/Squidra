#!/usr/bin/env python3
"""Scoped App API jobs. Credentials stay in memory and are revoked on exit."""
import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time
import urllib.request
import urllib.error

APP = 5587098
INSTALLATION = 177992380
REPOSITORIES = {'Tooflex/Squidra', 'Tooflex/Squidra-governance-qualification'}
PERMISSIONS = {'contents': 'write', 'issues': 'write', 'pull_requests': 'write', 'metadata': 'read'}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Redirect refused')


def api(method, path, credential, body=None):
    if not path.startswith('/') or '?' in path or '#' in path or '..' in path:
        raise ValueError('Invalid API path')
    request = urllib.request.Request('https://api.github.com' + path,
        data=None if body is None else json.dumps(body).encode(), method=method,
        headers={'Authorization': 'Bearer ' + credential, 'Accept': 'application/vnd.github+json',
                 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'Squidra-App-Job'})
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
        raw = response.read(2_000_001)
        if len(raw) > 2_000_000:
            raise ValueError('Oversized API response')
        return json.loads(raw) if raw else None


def jwt(key):
    info = key.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Key must be an owner-only regular file')
    def encode(data):
        return base64.urlsafe_b64encode(data).rstrip(b'=')
    now = int(time.time())
    message = encode(b'{"alg":"RS256","typ":"JWT"}') + b'.' + encode(json.dumps(
        {'iat': now - 60, 'exp': now + 540, 'iss': str(APP)}).encode())
    signature = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(key)],
        input=message, capture_output=True, timeout=10, check=True).stdout
    return (message + b'.' + encode(signature)).decode()


def validate_grant(grant, now):
    if grant['permissions'] != PERMISSIONS:
        raise ValueError('Unexpected permissions')
    remaining = (datetime.fromisoformat(grant['expires_at'].replace('Z', '+00:00')) - now).total_seconds()
    if not 60 < remaining <= 3660:
        raise ValueError('Invalid credential lifetime')


@contextmanager
def installation_job(repository, key, call=api, sign=jwt):
    if repository not in REPOSITORIES:
        raise ValueError('Repository not authorized')
    app_credential = sign(key)
    identity = call('GET', '/app', app_credential)
    if identity['id'] != APP or identity['slug'] != 'tooflex-squidra-bot':
        raise ValueError('Wrong App identity')
    installation = call('GET', f'/app/installations/{INSTALLATION}', app_credential)
    if (installation['app_id'] != APP or installation['account']['login'] != 'Tooflex'
            or installation['repository_selection'] != 'selected' or installation['permissions'] != PERMISSIONS):
        raise ValueError('Unexpected installation')
    grant = call('POST', f'/app/installations/{INSTALLATION}/access_tokens', app_credential,
                 {'repositories': [repository.split('/')[1]], 'permissions': PERMISSIONS})
    credential = grant['token']
    try:
        validate_grant(grant, datetime.now(timezone.utc))
        listing = call('GET', '/installation/repositories', credential)
        if listing['total_count'] != 1 or [r['full_name'] for r in listing['repositories']] != [repository]:
            raise ValueError('Unexpected repository scope')
        def request(method, suffix, body=None):
            if not suffix.startswith('/') or '..' in suffix or '?' in suffix or '#' in suffix:
                raise ValueError('Invalid repository route')
            return call(method, '/repos/' + repository + suffix, credential, body)
        yield request
    finally:
        call('DELETE', '/installation/token', credential)


def merge(request, repository, number, tested_sha):
    if not re.fullmatch(r'[0-9a-f]{40}', tested_sha) or number < 1:
        raise ValueError('Invalid merge identity')
    pr = request('GET', f'/pulls/{number}')
    if (pr['head']['repo']['full_name'] != repository or
            not re.fullmatch(r'bot/[0-9]+-[a-z0-9-]+', pr['head']['ref']) or
            pr['head']['sha'] != tested_sha or pr['base']['ref'] != 'main' or pr['draft']):
        raise ValueError('PR is not the tested bot head')
    return request('PUT', f'/pulls/{number}/merge', {'sha': tested_sha, 'merge_method': 'merge'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', choices=sorted(REPOSITORIES), default='Tooflex/Squidra')
    parser.add_argument('--key-file', type=Path, required=True)
    parser.add_argument('--merge-pr', type=int)
    parser.add_argument('--tested-sha')
    args = parser.parse_args()
    def terminate(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, terminate)
    if (args.merge_pr is None) != (args.tested_sha is None):
        parser.error('Merge requires both PR number and locally tested head SHA')
    try:
        with installation_job(args.repository, args.key_file) as request:
            if args.merge_pr is not None:
                result = merge(request, args.repository, args.merge_pr, args.tested_sha)
                if result.get('merged') is not True:
                    raise ValueError('Merge not confirmed')
                report = {'status': 'merged', 'sha': result['sha']}
            else:
                request('GET', '/branches/main')
                report = {'status': 'qualified', 'repository': args.repository}
        print(json.dumps(dict(report, credential_revoked=True)))
        return 0
    except (Exception, KeyboardInterrupt):
        # Never echo provider error bodies, subprocess output or credentials.
        print('{"status":"failed","reason":"App job failed; no credential details logged"}')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
