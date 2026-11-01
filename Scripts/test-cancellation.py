#!/usr/bin/env python3
"""Qualify cancellation ports, durable waiters, HTTP runs and uncertain effects."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUITES = [
    ("T14-RUN", "runtime_cancellation"),
    ("SQD-009", "approval_withdrawal"),
    ("SQD-008", "gateway_cancellation"),
    ("SQD-007", "durable_unknown_effects"),
    ("T05-HTTP", "http_durable_cancellation"),
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
