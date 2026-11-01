#!/usr/bin/env python3
"""SIGKILL only owned fixture processes, then recover in fresh processes."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parent.parent
credential_path, port = sys.argv[1:3]
credentials = dict(line.split('=', 1) for line in Path(credential_path).read_text().splitlines())
env = dict(os.environ, SQUIDRA_MOVEMENT_CRASH_FIXTURE='1', SQUIDRA_TEST_DB_PORT=port,
           SQUIDRA_TEST_DB_PASSWORD=credentials['POSTGRES_PASSWORD'])
subprocess.run(['swift', 'build', '--force-resolved-versions', '--product', 'squidra-movement-crash-fixture'], cwd=root, check=True)
bin_path = subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip()
exe = str(Path(bin_path) / 'squidra-movement-crash-fixture')
with tempfile.TemporaryDirectory(prefix='squidra-movement-crash-') as temp:
    for stage in ['saved', 'published']:
        marker = Path(temp) / (stage + '.json')
        with (Path(temp) / (stage + '.log')).open('w+') as log:
            process = subprocess.Popen([exe, 'seed', stage, str(marker)], cwd=root, env=env,
                                       stdout=log, stderr=log)
            try:
                end = time.monotonic() + 30
                while not marker.exists():
                    if process.poll() is not None or time.monotonic() >= end:
                        raise RuntimeError('Owned fixture did not reach its durable crash boundary')
                    time.sleep(0.02)
                data = json.loads(marker.read_text())
                if data.get('stage') != stage or process.poll() is not None:
                    raise RuntimeError('Invalid crash boundary')
                process.kill()
                if process.wait(timeout=10) != -signal.SIGKILL:
                    raise RuntimeError('Fixture did not exit through SIGKILL')
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
            resumed = subprocess.run([exe, 'resume', stage, str(marker)], cwd=root, env=env,
                                     capture_output=True, text=True, timeout=30)
            if resumed.returncode or resumed.stdout.strip() != 'CRASH_RECOVERY_VERIFIED':
                raise RuntimeError('Fresh process did not verify recovery')
            print('SQUIDRA_TEST_PASS:crash_' + stage, flush=True)
