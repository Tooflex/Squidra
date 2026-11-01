#!/usr/bin/env python3
"""Isolated local PostgreSQL harness for the real Swift media adapter."""
import json
import os
from pathlib import Path
import secrets
import socket
import sys
import subprocess
import tempfile
import time
import uuid

root = Path(__file__).resolve().parents[2]
engine = os.environ.get('SQUIDRA_CONTAINER_ENGINE', 'docker')
name = 'squidra-client-test-' + uuid.uuid4().hex[:12]
nonce = uuid.uuid4().hex
identity = None
suite = sys.argv[1] if len(sys.argv) == 2 else 'T12-MEDIA-SWIFT'
if suite not in {'T12-MEDIA-SWIFT', 'T12-EXPORT-SWIFT'} or len(sys.argv)>2:
    raise SystemExit('Unknown lifecycle suite')
expected = 5
marker = 'media_adapter' if suite == 'T12-MEDIA-SWIFT' else 'structural_export'

def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=180, capture_output=True, **kwargs)

try:
    with tempfile.TemporaryDirectory(prefix='squidra-media-') as directory:
        credentials = Path(directory) / 'credentials'
        credentials.touch(mode=0o600)
        credentials.write_text('POSTGRES_DB=squidra\nPOSTGRES_USER=squidra\nPOSTGRES_PASSWORD=' + secrets.token_urlsafe(32) + '\n')
        identity = run([engine,'create','--name',name,'--label','io.squidra.database=test','--label','io.squidra.media-test='+nonce,'--publish','127.0.0.1::5432','--env-file',str(credentials),'--tmpfs','/var/lib/postgresql/data:rw,nosuid,size=1g','localhost/squidra-postgres:17-postgis3.6.4-vector0.8.7']).stdout.decode().strip()
        run([engine,'start',identity])
        for _ in range(60):
            if subprocess.run([engine,'exec',identity,'pg_isready','-U','squidra','-d','squidra'],capture_output=True).returncode == 0:
                break
            time.sleep(.25)
        else: raise RuntimeError('Readiness failed')
        binding=run([engine,'port',name,'5432/tcp']).stdout.decode().strip()
        if not binding.startswith('127.0.0.1:') or not binding.split(':')[1].isdigit(): raise RuntimeError('Unexpected binding')
        reachability = time.monotonic() + 10
        while True:
            try:
                with socket.create_connection(('127.0.0.1',int(binding.split(':')[1])),timeout=1): pass
                break
            except OSError:
                if time.monotonic() >= reachability: raise RuntimeError('Database loopback unavailable; use the configured Colima wrapper')
                time.sleep(.1)
        env=dict(os.environ,SQUIDRA_DB_CONTAINER=name,SQUIDRA_CONTAINER_ENGINE=engine)
        run(['bash','Scripts/dev-db.sh','migrate'],cwd=root,env=env)
        report=root/'.build/issue-tests'/suite/'summary.json'
        report.unlink(missing_ok=True)
        result=subprocess.run(['python3','Scripts/run-db-client-tests.py',str(credentials),binding.split(':')[1],suite],cwd=root,env=env,capture_output=True,timeout=300)
        output=result.stdout.decode()+result.stderr.decode()
        print('\n'.join(line for line in output.splitlines() if not line.startswith('SQUIDRA_TEST_PASS:')))
        if result.returncode: raise SystemExit(result.returncode)
        data=json.loads(report.read_text())
        if data['status']!='passed' or data['selected']!=expected or data['passed']!=expected or any(data[k] for k in ['failed','skipped','not_executed']): raise RuntimeError('Incomplete Swift checks')
        print('SQUIDRA_TEST_PASS:'+marker)
finally:
    if identity:
        info=json.loads(run([engine,'inspect',identity]).stdout)[0]
        if info['Config']['Labels'].get('io.squidra.media-test')!=nonce: raise RuntimeError('Ownership mismatch')
        # Use owned name so the Colima wrapper also removes its own loopback forward.
        run([engine,'rm','-f',name])
