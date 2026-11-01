#!/usr/bin/env python3
"""Qualify official AG-UI contracts and the complete durable run transport."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUITES = [
    ("T05-CONTRACTS", "official_agui_contracts"),
    ("T05-SQL", "durable_scoped_replay"),
    ("T05-PUBLICATION", "atomic_publication"),
    ("T05-WORKERS", "owned_worker_lifecycle"),
    ("T05-HTTP", "authenticated_http_transport"),
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
