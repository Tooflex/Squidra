#!/usr/bin/env python3
"""Noninteractive authored historical replay on an owned isolated PostgreSQL DB."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import uuid

root=Path(__file__).resolve().parents[2]
engine=os.environ.get('SQUIDRA_CONTAINER_ENGINE','docker')
nonce=uuid.uuid4().hex;name='squidra-client-test-'+nonce[:12];identity=None
out=root/'.build/demo'/nonce;out.mkdir(parents=True,mode=0o700)
def run(args,**kwargs):
    result=subprocess.run(args,capture_output=True,timeout=180,**kwargs)
    if result.returncode:
        (out/'failure.log').write_bytes(result.stdout+result.stderr)
        raise RuntimeError('Demo command failed; inspect the private failure log')
    return result
try:
    scenario_data=json.loads((root/'fixtures/demo/scenario.json').read_text())
    for weekday,key in enumerate(['monday','tuesday','wednesday','movement']):
        value=scenario_data[key]
        if not value.endswith('Z') or datetime.fromisoformat(value.replace('Z','+00:00')).weekday()!=weekday:raise RuntimeError('Invalid authored UTC weekday')
    build=run(['swift','build','--force-resolved-versions','--product','squidra-demo-fixture'],cwd=root)
    (out/'build.log').write_bytes(build.stdout+build.stderr)
    bin_dir=run(['swift','build','--show-bin-path'],cwd=root).stdout.decode().strip()
    executable=str(Path(bin_dir)/'squidra-demo-fixture')
    with tempfile.TemporaryDirectory(prefix='private-',dir=out) as temporary:
        temp=Path(temporary);credentials=temp/'postgres.env';credentials.touch(mode=0o600)
        password=secrets.token_urlsafe(32)
        credentials.write_text('POSTGRES_DB=squidra\nPOSTGRES_USER=squidra\nPOSTGRES_PASSWORD='+password+'\n')
        identity=run([engine,'create','--name',name,'--label','io.squidra.database=test','--label','io.squidra.demo='+nonce,'--publish','127.0.0.1::5432','--env-file',str(credentials),'--tmpfs','/var/lib/postgresql/data:rw,nosuid,size=1g','localhost/squidra-postgres:17-postgis3.6.4-vector0.8.7']).stdout.decode().strip()
        run([engine,'start',identity])
        for _ in range(60):
            if subprocess.run([engine,'exec',identity,'pg_isready','-U','squidra','-d','squidra'],capture_output=True).returncode==0:break
            time.sleep(.25)
        else:raise RuntimeError('Demo database not ready')
        binding=run([engine,'port',name,'5432/tcp']).stdout.decode().strip()
        if not binding.startswith('127.0.0.1:'):raise RuntimeError('Unexpected database binding')
        port=binding.split(':')[1]
        with socket.create_connection(('127.0.0.1',int(port)),timeout=5):pass
        run(['bash','Scripts/dev-db.sh','migrate'],cwd=root,env=dict(os.environ,SQUIDRA_DB_CONTAINER=name,SQUIDRA_CONTAINER_ENGINE=engine))
        env={'PATH':os.environ['PATH'],'HOME':temporary,'SQUIDRA_DEMO_FIXTURE':'1','SQUIDRA_TEST_DB_PORT':port,'SQUIDRA_TEST_DB_PASSWORD':password}
        receipt=temp/'identity.json';report=out/'evidence.json';scenario=root/'fixtures/demo/scenario.json'
        for mode in ['seed','verify','verify']:
            result=run([executable,mode,str(scenario),str(receipt),str(report)],cwd=root,env=env)
            if result.stdout.decode().splitlines().count('HISTORICAL_DEMO_VERIFIED')!=1:raise RuntimeError('Incomplete demo process')
        evidence=json.loads(report.read_text())
        assert evidence['mondayEarly']['location']=='desk' and evidence['mondayCorrected']['location']=='drawer'
        assert evidence['tuesday']['location']=='shelf' and evidence['notificationCount']==1
        assert evidence['unknown']=='noEvidence' and evidence['modelMode']=='none' and evidence['realModelExecuted'] is False
        assert evidence['mondayEarly']['sourceEventID']!=evidence['mondayCorrected']['sourceEventID']
        assert all(evidence[key]['confidence']==0.8 for key in ['mondayEarly','mondayCorrected','tuesday'])
        print('SQUIDRA_TEST_PASS:historical_knowledge_correction')
        print('SQUIDRA_TEST_PASS:unique_movement_notification')
        print('SQUIDRA_TEST_PASS:fresh_process_reproduction')
        print('SQUIDRA_TEST_PASS:unknown_and_actor_isolation')
        manifest={'checked_at_utc':datetime.now(timezone.utc).isoformat(),'source_commit':run(['git','rev-parse','HEAD'],cwd=root).stdout.decode().strip(),'source_dirty':bool(run(['git','status','--porcelain'],cwd=root).stdout.strip()),'evidence_sha256':hashlib.sha256(report.read_bytes()).hexdigest(),'scope':'authored fixture; PostgreSQL production projection/watch APIs; no LLM','fresh_process_verifications':2}
        (out/'verification.json').write_text(json.dumps(manifest,indent=2)+'\n')
finally:
    if identity:
        info=json.loads(run([engine,'inspect',identity]).stdout)[0]
        if info['Config']['Labels'].get('io.squidra.demo')!=nonce:raise RuntimeError('Database ownership mismatch')
        run([engine,'rm','-f',name])
        if run([engine,'ps','--all','--filter','id='+identity,'--format','{{.ID}}']).stdout.strip():raise RuntimeError('Demo cleanup incomplete')
print('SQUIDRA_TEST_PASS:demo_cleanup')
print(json.dumps({'evidence_directory':str(out)}))
