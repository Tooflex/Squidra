#!/usr/bin/env python3
"""Offline issue gates; paid qualification is deliberately excluded."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SUITES = {
    'T11': ['T11-CONTRACTS', 'T11-META-RESPONSES', 'T11-META-TRANSPORT',
            'T11-META-COST', 'T11-META-MODEL', 'T11-META-BUDGET',
            'T11-META-HOST', 'T11-SAM-IMAGE', 'T11-SAM-NATIVE', 'T11-SAM-ADMISSION'],
    'SQD-020': ['SQD-020-OFFLINE', 'T11-SAM-IMAGE', 'T11-SAM-NATIVE',
                'T11-SAM-ADMISSION', 'SQD-020-PUBLISH', 'SQD-020-HTTP'],
}


def marker(suite):
    return suite.lower().replace('-', '_')


def main(issue, root=ROOT, run=subprocess.run):
    if issue not in SUITES:
        return 2
    for suite in SUITES[issue]:
        report = root / '.build/issue-tests' / suite / 'summary.json'
        report.unlink(missing_ok=True)
        result = run(['bash', 'Scripts/test-issue.sh', suite], cwd=root,
                     text=True, capture_output=True)
        for line in result.stdout.splitlines():
            if not line.startswith('SQUIDRA_TEST_PASS:'):
                print(line, flush=True)
        print(result.stderr, file=sys.stderr, end='')
        if result.returncode:
            return result.returncode
        try:
            summary = json.loads(report.read_text())
            selected = summary['selected']
            if (type(selected) is not int or selected <= 0 or summary['status'] != 'passed'
                    or summary['passed'] != selected
                    or any(summary[k] != 0 for k in ['failed', 'skipped', 'not_executed'])):
                return 1
        except (OSError, ValueError, KeyError, TypeError):
            return 1
        print('SQUIDRA_TEST_PASS:' + marker(suite), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]) if len(sys.argv) == 2 else 2)
