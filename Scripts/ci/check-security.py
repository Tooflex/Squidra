#!/usr/bin/env python3
"""Run all local Security workflow gates; Bootstrap remains a separate gate."""
import json
from pathlib import Path
import subprocess

root=Path(__file__).resolve().parents[2]
suites=[('SQD-035-DEPENDENCY-CONTRACTS','dependency_contracts'),('SQD-035-DEPENDENCIES','dependencies'),('SQD-035-SWIFT-SAST-CONTRACTS','sast_contracts'),('SQD-035-SWIFT-SAST','sast'),('SQD-035-SECRET-CONTRACTS','secret_contracts'),('SQD-035-SECRETS','secrets'),('SQD-035-LINT-CONTRACTS','lint_contracts'),('SQD-035-LINT','lint')]
for suite,marker in suites:
    result=subprocess.run(['bash','Scripts/test-issue.sh',suite],cwd=root,capture_output=True,text=True,timeout=600)
    # Nested markers belong to their own reports, not the aggregate inventory.
    for line in result.stdout.splitlines():
        if not line.startswith('SQUIDRA_TEST_PASS:'):print(line)
    print(result.stderr,end='')
    if result.returncode:raise SystemExit(result.returncode)
    report=json.loads(result.stdout.splitlines()[-1])
    if report['status']!='passed' or report['selected']<=0 or report['passed']!=report['selected'] or any(report[key] for key in ['failed','skipped','not_executed']):raise SystemExit('Incomplete security gate')
    print('SQUIDRA_TEST_PASS:security_'+marker)
