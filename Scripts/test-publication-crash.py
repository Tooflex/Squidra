#!/usr/bin/env python3
"""Kill an owned completed worker, recover via the real model-free HTTP server."""
import http.client
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

ROOT = Path(__file__).resolve().parent.parent
credential_path, port = sys.argv[1:3]
mode = sys.argv[3] if len(sys.argv) == 4 else "completed"
if mode not in {"completed", "preplanning", "saved-plan", "saved-result"}:
    raise SystemExit("Unknown crash boundary")
early = mode != "completed"
seed_mode = {"completed": "seed", "preplanning": "seed-early", "saved-plan": "seed-plan", "saved-result": "seed-result"}[mode]
resume_mode = {"preplanning": "resume-early", "saved-plan": "resume-plan", "saved-result": "resume-result"}.get(mode)
verified = {"preplanning": "PREPLANNING_RECOVERY_VERIFIED", "saved-plan": "SAVED_PLAN_RECOVERY_VERIFIED", "saved-result": "SAVED_RESULT_RECOVERY_VERIFIED"}.get(mode)
prefix = {"completed": "completed", "preplanning": "preplanning", "saved-plan": "saved_plan", "saved-result": "saved_result"}[mode]
credentials = dict(line.split('=', 1) for line in Path(credential_path).read_text().splitlines())
env = dict(os.environ, SQUIDRA_PUBLICATION_CRASH_FIXTURE='1', SQUIDRA_TEST_DB_PORT=port,
           SQUIDRA_TEST_DB_PASSWORD=credentials['POSTGRES_PASSWORD'])
for product in ['squidra-publication-crash-fixture', 'squidra']:
    subprocess.run(['swift', 'build', '--force-resolved-versions', '--product', product], cwd=ROOT, check=True)
binaries = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
fixture = str(binaries / 'squidra-publication-crash-fixture')

def stop(process, abrupt=False):
    code = process.poll()
    if code is None:
        process.send_signal(signal.SIGKILL if abrupt else signal.SIGTERM)
        try:
            code = process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
            raise RuntimeError('Owned process did not stop')
    if code != (-signal.SIGKILL if abrupt else 0):
        raise RuntimeError('Unexpected owned process exit')

def start_server(server_env):
    process = subprocess.Popen([str(binaries / 'squidra'), 'serve'], cwd=ROOT, env=server_env,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            end = time.monotonic() + 20
            while time.monotonic() < end and process.poll() is None:
                if selector.select(timeout=0.1):
                    line = process.stdout.readline().strip()
                    if line.startswith('SQUIDRA listening 127.0.0.1:'):
                        return process, int(line.rsplit(':', 1)[1])
        raise RuntimeError('Server did not start')
    except BaseException:
        stop(process, abrupt=True)
        raise

def get(http_port, path, token):
    connection = http.client.HTTPConnection('127.0.0.1', http_port, timeout=5)
    try:
        connection.request('GET', path, headers={'Authorization': 'Bearer ' + token})
        response = connection.getresponse()
        data = response.read()
        if response.status != 200 or token.encode() in data or credentials['POSTGRES_PASSWORD'].encode() in data:
            raise RuntimeError('HTTP response failed or leaked a credential')
        return data
    finally:
        connection.close()

with tempfile.TemporaryDirectory(prefix='squidra-publication-crash-') as temp:
    marker = Path(temp) / 'committed.json'
    with (Path(temp) / 'seed.log').open('w') as log:
        seed = subprocess.Popen([fixture, seed_mode, str(marker)], cwd=ROOT, env=env, stdout=log, stderr=log)
        try:
            end = time.monotonic() + 30
            while not marker.exists():
                if seed.poll() is not None or time.monotonic() >= end:
                    raise RuntimeError('Fixture did not commit its crash boundary')
                time.sleep(0.02)
            if seed.poll() is not None:
                raise RuntimeError('Fixture exited before the kill boundary')
            manifest = json.loads(marker.read_text())
            stop(seed, abrupt=True)
        finally:
            if seed.poll() is None:
                stop(seed, abrupt=True)
    print('SQUIDRA_TEST_PASS:' + prefix + '_worker_sigkill', flush=True)
    if early:
        resumed = subprocess.run([fixture, resume_mode, str(marker)], cwd=ROOT, env=env,
                                 capture_output=True, text=True, timeout=15)
        if resumed.returncode or resumed.stdout.strip() != verified:
            diagnostic = resumed.stdout.strip()
            if diagnostic.startswith('PUBLICATION_FIXTURE_FAILED') and len(diagnostic) < 100 and all(c.isalnum() or c in '_:' for c in diagnostic):
                print(diagnostic, file=sys.stderr)
            raise RuntimeError('Fresh engine did not continue the original task')
        manifest = json.loads(marker.read_text())
        print('SQUIDRA_TEST_PASS:' + prefix + '_continuation', flush=True)
    token = secrets.token_hex(32)
    server_env = dict(env, SQUIDRA_PROFILE='offline', SQUIDRA_PORT='0', SQUIDRA_ACTOR_ID=manifest['actor'],
                      SQUIDRA_AUTH_TOKEN=token, SQUIDRA_UI_ORIGIN='http://localhost:3000',
                      SQUIDRA_DB_PORT=port, SQUIDRA_DB_USER='squidra', SQUIDRA_DB_NAME='squidra',
                      SQUIDRA_DB_PASSWORD=credentials['POSTGRES_PASSWORD'])
    path = '/api/v1/runs/' + manifest['run']
    first = None
    for restart in [False, True]:
        server, http_port = start_server(server_env)
        try:
            capabilities = json.loads(get(http_port, '/api/v1/run-capabilities', token))
            if capabilities.get('textRuns') is not False:
                raise RuntimeError('Recovery server unexpectedly had a model host')
            end = time.monotonic() + 35
            while True:
                status = json.loads(get(http_port, path, token))
                if status.get('outputReady') is True:
                    break
                if time.monotonic() >= end or server.poll() is not None:
                    raise RuntimeError('Completed answer was not recovered')
                time.sleep(0.1)
            body = get(http_port, path + '/events', token)
            records = [json.loads(line[6:]) for line in body.decode().splitlines() if line.startswith('data: ')]
            if len(records) != 6 or records[1].get('name') != 'squidra.grounded_answer.v1':
                raise RuntimeError('Unexpected recovered stream')
            if first is None:
                first = body
            elif first != body:
                raise RuntimeError('Second server changed the durable replay')
            checked = subprocess.run([fixture, 'verify', str(marker)], cwd=ROOT, env=env,
                                     capture_output=True, text=True, timeout=15)
            if checked.returncode or checked.stdout.strip() != 'PUBLICATION_RECOVERY_VERIFIED':
                raise RuntimeError('Durable runtime/archive verification failed')
            stop(server, abrupt=not restart)
        finally:
            if server.poll() is None:
                stop(server, abrupt=True)
        print('SQUIDRA_TEST_PASS:' + ('second_server_replay' if restart else 'model_free_server_recovery'), flush=True)
