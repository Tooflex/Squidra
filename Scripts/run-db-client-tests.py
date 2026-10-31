#!/usr/bin/env python3
"""Inject a temporary test credential without command-line arguments or output."""
import os
from pathlib import Path
import subprocess
import sys

credential_path, port = sys.argv[1:]
values = dict(line.split('=', 1) for line in Path(credential_path).read_text().splitlines())
env = dict(os.environ, SQUIDRA_TEST_DB_PORT=port, SQUIDRA_TEST_DB_PASSWORD=values['POSTGRES_PASSWORD'])
raise SystemExit(subprocess.run(['bash', 'Scripts/test-issue.sh', 'DB-CLIENT-SWIFT'], env=env).returncode)
