#!/usr/bin/env python3
"""Qualify text planning, evidence grounding, runtime and live HTTP composition."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUITES = [
    ("T14-PLANNING", "bounded_planning"),
    ("T14-EVIDENCE", "verified_evidence"),
    ("T14-RUN", "bounded_runtime"),
    ("T14-HOST", "offline_host_authority"),
    ("T14-SQL", "database_grounded_answer"),
    ("T05-HTTP", "live_read_transport"),
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
