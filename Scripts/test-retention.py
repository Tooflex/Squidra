#!/usr/bin/env python3
"""Qualify media, export, erasure and restoration across the native lifecycle."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUITES = [
    ('T12-MEDIA', 't12_media'),
    ('T12-EXPORT', 't12_export'),
    ('T12-BACKUP', 't12_backup'),
    ('T12-ERASURE-DECISIONS', 't12_decisions'),
    ('T12-ERASURE-FENCE', 't12_fence'),
    ('T12-ERASURE-ROWS', 't12_rows'),
    ('SQD-001', 't12_admission'),
    ('T12-ERASURE-NATIVE', 't12_native'),
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
