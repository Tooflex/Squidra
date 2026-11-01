#!/usr/bin/env python3
"""Qualify recovery checkpoints, effect reconciliation and automatic read hosts."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUITES = [
    ('SQD-028-UNIT', 'recovery_checkpoints'),
    ('SQD-009', 'recovery_approval_waits'),
    ('SQD-028-DURABLE', 'recovery_durable_reconciliation'),
    ('SQD-028-CRASH', 'recovery_effect_process_crashes'),
    ('SQD-028-OWNERSHIP', 'recovery_local_ownership'),
    ('SQD-028-OWNED-PUBLICATION-CRASH', 'recovery_cli_publication'),
    ('SQD-028-AUTOMATIC-HOST-CRASH', 'recovery_automatic_host'),
    ('T05-HTTP', 'recovery_http_status'),
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
