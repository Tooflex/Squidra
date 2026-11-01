#!/usr/bin/env python3
"""Compile the typed client and require all browser scenarios to actually pass."""
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
web = root / 'web'
report = web / 'test-results/report.json'
report.unlink(missing_ok=True)
mode = sys.argv[1] if len(sys.argv) == 2 else 'review'
if len(sys.argv) > 2 or mode not in ['review', 'timeline', 'approvals', 'import', 'questions']:
    sys.exit('Unknown browser suite')
selection = {'review': 'tests/review.spec.ts', 'timeline': 'tests/timeline/', 'approvals': 'tests/approvals/', 'import': 'tests/import/', 'questions': 'tests/questions/'}[mode]
expected = 11 if mode == 'questions' else 8 if mode == 'import' else 6
commands = [['npm', 'ci', '--ignore-scripts'], ['npx', '--no-install', 'playwright', 'install', 'chromium'], ['npm', 'test', '--', selection]]
if sys.platform.startswith('linux') and os.environ.get('CI') == 'true':
    commands[1].append('--with-deps')
for command in commands:
    result = subprocess.run(command, cwd=web)
    if result.returncode:
        sys.exit(result.returncode)
try:
    stats = json.loads(report.read_text())['stats']
    assert stats['expected'] == expected and all(stats[key] == 0 for key in ['unexpected', 'flaky', 'skipped'])
except (OSError, ValueError, KeyError, AssertionError):
    sys.exit('Browser report missing, incomplete, skipped, flaky or failed')
print('SQUIDRA_TEST_PASS:' + 'typed_web_' + mode)
