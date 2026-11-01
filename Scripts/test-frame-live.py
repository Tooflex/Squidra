#!/usr/bin/env python3
"""Qualify the static browser against normal CLI servers and isolated PostgreSQL."""
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
credentials = dict(line.split('=', 1) for line in Path(sys.argv[1]).read_text().splitlines())
password, db_port = credentials['POSTGRES_PASSWORD'], sys.argv[2]
fixture_env = dict(os.environ, SQUIDRA_BROWSER_FIXTURE='1', SQUIDRA_TEST_DB_PORT=db_port, SQUIDRA_TEST_DB_PASSWORD=password)
for product in ['squidra-frame-browser-fixture', 'squidra']:
    subprocess.run(['swift', 'build', '--force-resolved-versions', '--product', product], cwd=ROOT, check=True)
binaries = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
for command in [['npm', 'ci', '--ignore-scripts'], ['npm', 'run', 'build']]:
    subprocess.run(command, cwd=ROOT / 'web', check=True)
install = ['npx', '--no-install', 'playwright', 'install', 'chromium']
if sys.platform.startswith('linux') and os.environ.get('CI') == 'true':
    install.append('--with-deps')
subprocess.run(install, cwd=ROOT / 'web', check=True)


def stop(process, require_clean=False):
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
            raise RuntimeError('Owned process did not join after shutdown')
    if require_clean and process.returncode != 0:
        raise RuntimeError('Owned server shutdown failed')


def start(command, env, log, prefix, cwd=ROOT):
    stream = log.open('w')
    try:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=stream, stderr=stream)
    finally:
        stream.close()
    try:
        end = time.monotonic() + 20
        while time.monotonic() < end and process.poll() is None:
            match = re.search(re.escape(prefix) + r'([0-9]+)', log.read_text()[-65536:])
            if match:
                port = int(match.group(1))
                if not 1 <= port <= 65535:
                    raise RuntimeError('Invalid owned listener port')
                return process, port
            time.sleep(0.05)
        raise RuntimeError('Owned listener did not start')
    except BaseException:
        stop(process)
        raise


def readiness(port):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
    try:
        connection.request('GET', '/ready')
        response = connection.getresponse()
        if response.status != 200 or json.loads(response.read()) != {'status': 'ready'}:
            raise RuntimeError('Normal server not ready')
    finally:
        connection.close()


with tempfile.TemporaryDirectory(prefix='squidra-frame-live-') as directory:
    root = Path(directory)
    manifest = root / 'fixture.json'
    fixture = str(binaries / 'squidra-frame-browser-fixture')
    token = secrets.token_hex(32)
    def run_private(command, env, name):
        log = root / (name + '.log')
        with log.open('w') as stream:
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=stream, stderr=stream)
        try:
            try:
                result = process.wait(timeout=90)
            except subprocess.TimeoutExpired:
                stop(process)
                raise RuntimeError('Owned fixture timed out')
            if result != 0:
                raise RuntimeError('Owned integration step failed: ' + name)
            output = log.read_text()
            if token in output or password in output:
                raise RuntimeError('Credential appeared in private integration output')
            return output
        finally:
            stop(process)
    run_private([fixture, 'seed', str(manifest)], fixture_env, 'seed')
    info = json.loads(manifest.read_text())
    browser_keys = {'PATH', 'HOME', 'TMPDIR', 'TMP', 'TEMP', 'USER', 'USERNAME', 'LOGNAME', 'LANG', 'LC_ALL', 'DISPLAY', 'XAUTHORITY', 'XDG_RUNTIME_DIR', 'PLAYWRIGHT_BROWSERS_PATH', 'CI', 'SystemRoot', 'WINDIR'}
    browser_env = {key: value for key, value in os.environ.items() if key in browser_keys}
    ui, ui_port = start(['node', 'serve.mjs'], dict(browser_env, SQUIDRA_WEB_PORT='0'), root / 'ui.log', 'SQUIDRA web listening 127.0.0.1:', ROOT / 'web')
    server = None
    try:
        origin = 'http://127.0.0.1:' + str(ui_port)
        server_env = dict(browser_env, SQUIDRA_PORT='0', SQUIDRA_AUTH_TOKEN=token, SQUIDRA_ACTOR_ID=info['actor'], SQUIDRA_UI_ORIGIN=origin,
                          SQUIDRA_SYNTHETIC_IMPORT='1', SQUIDRA_SYNTHETIC_FIXTURE=str(ROOT / 'fixtures/providers/vision-synthetic.v1.json'),
                          SQUIDRA_SYNTHETIC_CAMERA_ID=info['camera'], SQUIDRA_SYNTHETIC_SCENE_ID=info['scene'], SQUIDRA_SYNTHETIC_COORDINATE_FRAME_ID=info['coordinate'],
                          SQUIDRA_DB_PORT=db_port, SQUIDRA_DB_USER='squidra', SQUIDRA_DB_PASSWORD=password, SQUIDRA_DB_NAME='squidra')
        for phase in ['import', 'reload']:
            server, port = start([str(binaries / 'squidra'), 'serve'], server_env, root / ('server-' + phase + '.log'), 'SQUIDRA listening 127.0.0.1:')
            readiness(port)
            env = dict(browser_env, SQUIDRA_WEB_PHASE=phase, SQUIDRA_WEB_MANIFEST=str(manifest), SQUIDRA_WEB_ORIGIN=origin,
                       SQUIDRA_API_ORIGIN='http://127.0.0.1:' + str(port), SQUIDRA_WEB_TOKEN=token)
            output = run_private(['node', 'web/tests/live-frame.mjs'], env, 'browser-' + phase)
            if output.strip() != 'SQUIDRA_FRAME_LIVE_PASS:' + phase:
                raise RuntimeError('Browser phase did not confirm completion')
            run_private([fixture, 'verify', str(manifest)], fixture_env, 'verify-' + phase)
            stop(server, require_clean=True)
            server = None
            print('SQUIDRA_TEST_PASS:frame_sql_' + phase, flush=True)
    finally:
        try:
            if server is not None:
                stop(server)
        finally:
            stop(ui, require_clean=True)
