#!/usr/bin/env python3
"""Qualify sourced consolidation from bounded import through durable owner review."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUITES = [
    ('SQD-029-UNIT', 'consolidation_proposals'),
    ('SQD-029-DURABLE', 'consolidation_durable_history'),
    ('SQD-029-HTTP', 'consolidation_authenticated_review'),
    ('T06-REVIEW', 'consolidation_browser_boundaries'),
    ('T06-REVIEW-LIVE', 'consolidation_import_browser_reload'),
]

for suite, marker in SUITES:
    result = subprocess.run(["bash", "Scripts/test-issue.sh", suite], cwd=ROOT,
                            text=True, capture_output=True)
    # Child markers belong to their own reports; do not count them twice.
    for line in result.stdout.splitlines():
        if not line.startswith("SQUIDRA_TEST_PASS:"):
            print(line, flush=True)
    print(result.stderr, file=sys.stderr, end="")
    if result.returncode:
        sys.exit(result.returncode)
    print("SQUIDRA_TEST_PASS:" + marker, flush=True)
