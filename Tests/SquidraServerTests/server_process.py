#!/usr/bin/env python3
"""Exercise the real binary, owned test database, loopback sockets and signals."""
import http.client
import json
import os
from pathlib import Path
import secrets
import selectors
import signal
import subprocess
import sys
import time
import uuid

engine, container = sys.argv[1:]
label = subprocess.check_output([engine, 'inspect', '--format', '{{index .Config.Labels "io.squidra.database"}}', container], text=True).strip()
if label != 'test':
    raise RuntimeError('Refusing to stop a database not labelled for tests')
binary = Path(subprocess.check_output(['swift', 'build', '--show-bin-path', '--force-resolved-versions'], text=True).strip()) / 'squidra'
env = dict(os.environ, SQUIDRA_PORT='0', SQUIDRA_PROFILE='offline', SQUIDRA_AUTH_TOKEN=secrets.token_hex(32),
           SQUIDRA_ACTOR_ID=str(uuid.uuid4()), SQUIDRA_UI_ORIGIN='http://localhost:3000',
           SQUIDRA_DB_PORT=os.environ['SQUIDRA_TEST_DB_PORT'], SQUIDRA_DB_USER='squidra',
           SQUIDRA_DB_PASSWORD=os.environ['SQUIDRA_TEST_DB_PASSWORD'], SQUIDRA_DB_NAME='squidra')

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def request(connection, path, headers=None):
    connection.request('GET', path, headers=headers or {})
    response = connection.getresponse()
    body = response.read()
    require(env['SQUIDRA_AUTH_TOKEN'].encode() not in body and env['SQUIDRA_DB_PASSWORD'].encode() not in body, 'Response leaked credentials')
    require(response.getheader('X-Request-ID') is not None, 'Missing request ID')
    return response.status, json.loads(body)

invalid = dict(env, SQUIDRA_UI_ORIGIN='https://user:private@example.com')
result = subprocess.run([str(binary), 'check-config'], env=invalid, capture_output=True, timeout=10)
require(result.returncode != 0, 'Invalid configuration accepted')
require(b'private' not in result.stderr and env['SQUIDRA_DB_PASSWORD'].encode() not in result.stderr, 'Startup leaked configuration')
print('SQUIDRA_TEST_PASS:configuration_redaction', flush=True)

for stop_signal in [signal.SIGTERM, signal.SIGINT]:
    process = subprocess.Popen([str(binary), 'serve'], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    connection = None
    try:
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        until = time.monotonic() + 20
        port = None
        while time.monotonic() < until and process.poll() is None:
            if selector.select(timeout=0.2):
                line = process.stdout.readline().strip()
                if line.startswith('SQUIDRA listening 127.0.0.1:'):
                    port = int(line.rsplit(':', 1)[1]); break
        selector.close()
        require(port is not None, 'Server did not bind to loopback')
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
        require(request(connection, '/health') == (200, {'status':'alive'}), 'Liveness failed')
        require(request(connection, '/ready') == (200, {'status':'ready'}), 'Real database readiness failed')
        require(request(connection, '/api/v1/unknown')[0] == 401, 'Protected unknown path lacked authentication')
        require(request(connection, '/api/v1/unknown', {'Authorization':'Bearer '+env['SQUIDRA_AUTH_TOKEN']})[0] == 404, 'Valid host credential rejected')
        if stop_signal == signal.SIGTERM:
            print('SQUIDRA_TEST_PASS:server_startup_and_auth', flush=True)
        else:
            subprocess.run([engine, 'stop', '--time', '2', container], check=True, stdout=subprocess.DEVNULL)
            require(request(connection, '/health') == (200, {'status':'alive'}), 'Database loss broke liveness')
            require(request(connection, '/ready') == (503, {'status':'not_ready','dependency':'database'}), 'Database loss did not fail readiness')
            print('SQUIDRA_TEST_PASS:database_down_probes', flush=True)
        process.send_signal(stop_signal)
        require(process.wait(timeout=10) == 0, 'Signal shutdown did not finish cleanly')
        try:
            connection.request('GET', '/health')
            connection.getresponse()
        except (OSError, http.client.HTTPException):
            pass
        else:
            raise RuntimeError('HTTP listener survived process shutdown')
        print('SQUIDRA_TEST_PASS:'+('sigterm_shutdown' if stop_signal == signal.SIGTERM else 'sigint_shutdown'), flush=True)
    finally:
        if connection:
            connection.close()
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
