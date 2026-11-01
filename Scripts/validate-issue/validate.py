#!/usr/bin/env python3
"""Validate untrusted issue text and current GitHub permissions; never dispatch code."""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

FIELDS = ('Context', 'Acceptance criteria', 'Allowed paths', 'Fixtures', 'Tests',
          'Risks and rollback', 'Budget')
PLACEHOLDERS = {'_no response_', 'none', 'n/a', 'todo', 'tbd', '-', '...'}


def validate_body(body):
    if not isinstance(body, str) or not 1 <= len(body.encode()) <= 32768:
        raise ValueError('invalid_body_size')
    sections = {}
    heading = None
    for line in body.splitlines():
        if line.startswith('### '):
            heading = line[4:].strip()
            if heading not in FIELDS or heading in sections:
                raise ValueError('invalid_or_duplicate_heading')
            sections[heading] = []
        elif heading:
            sections[heading].append(line)
        elif line.strip():
            raise ValueError('unexpected_preamble')
    if set(sections) != set(FIELDS):
        raise ValueError('missing_required_field')
    values = {key: '\n'.join(lines).strip() for key, lines in sections.items()}
    if any(not value or value.lower() in PLACEHOLDERS for value in values.values()):
        raise ValueError('empty_required_field')
    criteria = values['Acceptance criteria'].splitlines()
    if not all(re.fullmatch(r'- \[ \] \S.{4,}', line) for line in criteria):
        raise ValueError('invalid_acceptance_checklist')
    paths = values['Allowed paths'].splitlines()
    if len(paths) > 50:
        raise ValueError('too_many_paths')
    for path in paths:
        if (len(path) > 256 or not re.fullmatch(r'[A-Za-z0-9_.*/-]+', path)
                or path.startswith(('/', '-'))
                or any(part in {'..', '.git'} for part in path.split('/'))
                or not any(c.isalnum() for c in path)):
            raise ValueError('invalid_repository_path')
    budget = re.fullmatch(r'minutes: ([1-9][0-9]{0,2})\nfiles: ([1-9][0-9]?)', values['Budget'])
    if not budget or int(budget[1]) > 480 or int(budget[2]) > 50:
        raise ValueError('invalid_budget')
    return {'body_sha256': hashlib.sha256(body.encode()).hexdigest(),
            'criteria_count': len(criteria), 'path_count': len(paths),
            'minutes': int(budget[1]), 'files': int(budget[2])}


def github(path):
    # Arguments are separate; issue text is never interpolated into a shell.
    result = subprocess.run(['gh', 'api', path], capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise ValueError('github_verification_unavailable')
    return json.loads(result.stdout)


def authorize(issue, repository, number, actor, fetch=None):
    fetch = fetch or github
    if (not isinstance(issue, dict) or issue.get('number') != number or issue.get('state') != 'open'
            or 'pull_request' in issue or issue.get('repository_url') != f'https://api.github.com/repos/{repository}'):
        raise ValueError('issue_identity_mismatch')
    author = issue.get('user', {})
    if not isinstance(author, dict) or author.get('type') != 'User':
        raise ValueError('human_author_required')
    for login in {actor, author.get('login', '')}:
        if not isinstance(login, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,38}', login):
            raise ValueError('invalid_identity')
        permission = fetch(f'repos/{repository}/collaborators/{login}/permission')
        if (not isinstance(permission, dict) or not isinstance(permission.get('user'), dict)
                or permission['user'].get('login', '').lower() != login.lower()):
            raise ValueError('permission_identity_mismatch')
        if permission.get('permission') not in {'admin', 'write', 'maintain'}:
            raise ValueError('insufficient_permission')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--issue', required=True, type=int)
    args = parser.parse_args()
    # Repository and actor come from the Actions runner, never from issue text.
    repository = os.environ.get('GITHUB_REPOSITORY', '')
    actor = os.environ.get('GITHUB_ACTOR', '')
    try:
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository) or args.issue <= 0:
            raise ValueError('invalid_repository_or_issue')
        issue = github(f'repos/{repository}/issues/{args.issue}')
        authorize(issue, repository, args.issue, actor)
        requester = os.environ.get('GITHUB_TRIGGERING_ACTOR', actor)
        if requester != actor:
            authorize(issue, repository, args.issue, requester)
        report = validate_body(issue.get('body'))
        report.update(status='validated', issue=args.issue, dispatched=False)
        print(json.dumps(report, sort_keys=True))
        return 0
    except (ValueError, OSError, subprocess.TimeoutExpired):
        # Neither API errors nor user text, tokens or titles are echoed into logs.
        print(json.dumps({'status': 'rejected', 'dispatched': False}))
        return 1


if __name__ == '__main__':
    sys.exit(main())
