#!/usr/bin/env python3
"""Qualify private SDK tracing through ports, PostgreSQL and live HTTP workers."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUITES = [
    ("SQD-030-UNIT", "private_sdk_contracts"),
    ("SQD-030-PORTS", "port_correlation"),
    ("SQD-030-SQL", "durable_source_correlation"),
    ("T05-HTTP", "live_worker_tracing"),
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
