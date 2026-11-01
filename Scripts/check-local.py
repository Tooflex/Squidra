#!/usr/bin/env python3
"""Run the complete Bootstrap checks locally, stopping at the first failure."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--unit-only', action='store_true',
                        help='Omit Docker integration checks; report partial coverage')
    mode.add_argument('--integration-only', action='store_true',
                      help='Run only Docker integration suites; report partial coverage')
    args = parser.parse_args()
    suites = json.loads((ROOT / 'Scripts/issue-tests.json').read_text())
    selection = json.loads((ROOT / 'Scripts/local-checks.json').read_text())
    if not selection or len(selection) != len(set(selection)) or any(i not in suites for i in selection):
        parser.error('Local check selection must contain distinct registered issues')
    output = ROOT / '.build/local-checks' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    output.mkdir(parents=True)
    coverage = 'unit-only' if args.unit_only else 'integration-only' if args.integration_only else 'full'
    report = {'coverage': coverage, 'status': 'running',
              'steps': [], 'omitted': []}
    lock = ROOT / 'Package.resolved'
    digest = hashlib.sha256(lock.read_bytes()).hexdigest()

    def save():
        (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')

    def run(name, command, expect_empty=False):
        print(f'Running {name}', flush=True)
        start = time.monotonic()
        with (output / f'{name}.log').open('w') as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        ok = result.returncode == 0
        if expect_empty:
            summary = ROOT / '.build/issue-tests/T01/summary.json'
            ok = result.returncode == 1 and summary.exists() and json.loads(summary.read_text())['status'] == 'empty_selection'
        report['steps'].append({'name': name, 'exit_code': result.returncode,
                                'status': 'passed' if ok else 'failed',
                                'seconds': round(time.monotonic() - start, 2)})
        save()
        if not ok:
            raise RuntimeError(f'{name} failed; see {output / (name + ".log")}')

    save()
    try:
        run('swift-version', ['swift', '--version'])
        run('schema', ['python3', 'Scripts/schema-manifest.py', '--check'])
        run('runner', ['python3', 'Scripts/test_issue_runner.py'])
        run('local-runner', ['python3', 'Scripts/test_local_checks.py'])
        run('build', ['swift', 'build', '--force-resolved-versions'])
        if not args.unit_only:
            run('database-build', ['bash', 'Scripts/dev-db.sh', 'build'])
        run('empty-selection', ['bash', 'Scripts/test-issue.sh', 'T01', '--filter', '^MissingSuite/'], True)
        for issue in selection:
            if ((args.unit_only and suites[issue]['kind'] == 'command') or
                    (args.integration_only and suites[issue]['kind'] != 'command')):
                report['omitted'].append(issue)
                continue
            run(issue, ['bash', 'Scripts/test-issue.sh', issue])
        run('cli-help', ['swift', 'run', '--skip-build', 'squidra'])
        if hashlib.sha256(lock.read_bytes()).hexdigest() != digest:
            raise RuntimeError('Package.resolved changed during local checks')
        report['status'] = 'passed'
    except (RuntimeError, OSError, ValueError, KeyboardInterrupt) as error:
        report['status'] = 'failed'
        report['error'] = str(error) or 'Interrupted'
        print(report['error'], file=sys.stderr)
    finally:
        completed = {step['name'] for step in report['steps']}
        report['not_executed'] = [i for i in selection if i not in completed and i not in report['omitted']]
        save()
        print(f'Report: {output / "summary.json"}', flush=True)
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
