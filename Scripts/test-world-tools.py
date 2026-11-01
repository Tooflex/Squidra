#!/usr/bin/env python3
"""Qualify scoped world reads and durable watch mutations through the gateway."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUITES = [
    ("T13-LOCATION", "location_contract"),
    ("T13-CHANGES", "changes_contract"),
    ("T13-WATCH-CONTRACT", "watch_contract"),
    ("T13-READS", "gateway_database"),
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
