#!/usr/bin/env python3
"""Inject a temporary test credential without command-line arguments or output."""
import os
from pathlib import Path
import subprocess
import sys

credential_path, port = sys.argv[1:3]
suite = sys.argv[3] if len(sys.argv) > 3 else "DB-CLIENT-SWIFT"
values = dict(line.split('=', 1) for line in Path(credential_path).read_text().splitlines())
env = dict(os.environ, SQUIDRA_TEST_DB_PORT=port, SQUIDRA_TEST_DB_PASSWORD=values['POSTGRES_PASSWORD'])
result = subprocess.run(['bash', 'Scripts/test-issue.sh', suite], env=env)
if result.returncode:
    raise SystemExit(result.returncode)
if suite == 'SQD-001-SWIFT':
    raise SystemExit(subprocess.run(['python3', 'Tests/SquidraServerTests/server_process.py', *sys.argv[4:]], env=env).returncode)
