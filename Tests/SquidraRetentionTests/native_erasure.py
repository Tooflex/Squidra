"""Qualify native-process exclusion and erasure only in the harness-owned database."""
import http.client
import importlib.util
import json
import os
from pathlib import Path
import secrets
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
credential_path, db_port, engine, container = sys.argv[1:]
info = json.loads(subprocess.check_output([engine, 'inspect', container]))[0]
assert info['Config']['Labels'].get('io.squidra.database') == 'test'
identity = info['Id']
credentials = dict(line.split('=', 1) for line in Path(credential_path).read_text().splitlines())
binary = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], text=True).strip())/'squidra'
actor, other, third = [str(uuid.uuid4()) for _ in range(3)]
processes = []

def sql(query):
    result = subprocess.run([engine,'exec','-i',identity,'psql','-X','-A','-t','-q','-v','ON_ERROR_STOP=1','-U','squidra','-d','squidra'], input=query.encode(), capture_output=True, timeout=30)
    assert result.returncode == 0, 'Fixture SQL failed (content withheld)'
    return result.stdout.decode().strip()

def stop(process):
    process.send_signal(signal.SIGTERM)
    assert process.wait(timeout=15) == 0

def start(env):
    process = subprocess.Popen([str(binary),'serve'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    processes.append(process)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    end = time.monotonic()+20
    try:
        while time.monotonic()<end and process.poll() is None:
            if selector.select(.2):
                line = process.stdout.readline().strip()
                if line.startswith('SQUIDRA listening 127.0.0.1:'):
                    return process, int(line.rsplit(':',1)[1])
        raise AssertionError('Native fixture failed to start')
    finally:
        selector.close()

def request(port):
    connection = http.client.HTTPConnection('127.0.0.1',port,timeout=5)
    try:
        connection.request('GET','/ready')
        response = connection.getresponse()
        return response.status, json.loads(response.read())
    finally:
        connection.close()

try:
    with tempfile.TemporaryDirectory(prefix='squidra-native-erasure-') as temporary:
        root = Path(temporary).resolve()
        authority = root/'authority'; authority.mkdir(mode=0o700)
        spec = importlib.util.spec_from_file_location('decisions',ROOT/'Scripts/account-erasure/decisions.py')
        decisions = importlib.util.module_from_spec(spec);spec.loader.exec_module(decisions)
        decisions.initialize(authority)
        env = dict(os.environ,SQUIDRA_PROFILE='offline',SQUIDRA_PORT='0',SQUIDRA_UI_ORIGIN='http://localhost:3000',SQUIDRA_AUTH_TOKEN=secrets.token_hex(32),SQUIDRA_ACTOR_ID=actor,SQUIDRA_DB_PORT=db_port,SQUIDRA_DB_USER='squidra',SQUIDRA_DB_PASSWORD=credentials['POSTGRES_PASSWORD'],SQUIDRA_DB_NAME='squidra',SQUIDRA_ERASURE_AUTHORITY_DIRECTORY=str(authority))
        env.pop('SQUIDRA_RUN_DIRECTORY',None)
        for value in [actor,other,third]:
            sql(f"INSERT INTO world_entities(id,actor_id,kind) VALUES(gen_random_uuid(),'{value}','native-erasure-fixture')")
        tables = sql("SELECT table_name FROM information_schema.columns WHERE table_schema='public' AND column_name='actor_id' AND table_name NOT IN ('account_erasure_fences','account_database_erasure_receipts') ORDER BY table_name").splitlines()
        assert len(tables)==27
        def snapshot(value):
            return {table:sql(f"SELECT row_to_json(t)::text FROM {table} t WHERE actor_id='{value}' ORDER BY row_to_json(t)::text") for table in tables}
        before, preserved = snapshot(actor), snapshot(other)
        first, first_port = start(env)
        second, second_port = start(env)
        foreign, foreign_port = start(dict(env,SQUIDRA_ACTOR_ID=other))
        def erase(value=actor, run_directory=None, status='erased'):
            command = [sys.executable,str(ROOT/'Scripts/account-erasure/erase.py'),'--authority',str(authority),'--actor',value,'--container',container]
            command += ['--run-directory',str(run_directory)] if run_directory else ['--no-local-run-directory']
            result = subprocess.run(command,capture_output=True,timeout=150)
            report = json.loads(result.stdout)
            assert report['status']==status and result.returncode=={'erased':0,'busy':2,'failed':1}[status], 'Unexpected erasure outcome'
            return report
        erase(status='busy')
        assert snapshot(actor)==before
        assert sql(f"SELECT erased FROM account_erasure_fences WHERE actor_id='{actor}'")=='f'
        assert actor in decisions.snapshot(authority)['actors']
        assert request(first_port)==(503,{'status':'not_ready','dependency':'account'})
        assert request(foreign_port)==(200,{'status':'ready'})
        first.kill()
        assert first.wait(timeout=10) == -signal.SIGKILL
        erase(status='busy')
        assert snapshot(actor)==before
        stop(second)
        report = erase()
        assert not any(snapshot(actor).values()) and snapshot(other)==preserved
        assert erase()['receipt_id']==report['receipt_id']
        assert request(foreign_port)==(200,{'status':'ready'})
        rejected = subprocess.run([str(binary),'serve'],env=env,capture_output=True,timeout=15)
        assert rejected.returncode != 0 and b'SQUIDRA listening' not in rejected.stdout
        print('SQUIDRA_TEST_PASS:native_process_quiescence',flush=True)
        # Unknown run storage refuses completion; minimum identity locks remain.
        directory=root/'runs';directory.mkdir(mode=0o700)
        unknown=directory/'unqualified-payload';unknown.write_text('fixture-payload')
        erase(third,directory,'failed')
        assert any(snapshot(third).values())
        unknown.unlink()
        lock=directory/(third+'.lock');lock.touch(mode=0o600);lock.write_text(str(uuid.uuid4())+'\n')
        inode=lock.stat().st_ino; raw=lock.read_bytes()
        erase(third,directory)
        assert lock.stat().st_ino==inode and lock.read_bytes()==raw
        assert not any(snapshot(third).values()) and snapshot(other)==preserved
        print('SQUIDRA_TEST_PASS:local_storage_inventory',flush=True)
        stop(foreign)
finally:
    for process in processes:
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill();process.wait()
