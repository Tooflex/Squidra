#!/usr/bin/env python3
"""Qualify two owned server processes against one isolated durable database."""
import copy
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import uuid


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def passed(name):
    print('SQUIDRA_TEST_PASS:' + name, flush=True)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def validate_bodies(bodies, fixture):
    require(len(bodies) == 4, 'Missing structured responses')
    actor = fixture['actorId'].lower()
    tip = str(fixture['sourceEvents'][-1]['sequence'])
    for body in bodies:
        require(body.get('schemaVersion') == '1' and body.get('actorId') == actor, 'Foreign/versioned response')
        require(body.get('projectedThroughSequence') == tip and body.get('availableThroughSequence') == tip, 'Projection did not reach the actor snapshot')
    recorded = {event['id'].lower(): event['recordedAt'] for event in fixture['sourceEvents']}

    def facts(body, expected_ids):
        values = body.get('facts', [])
        require(len(values) == len(expected_ids), 'Missing or duplicate source facts')
        require({fact.get('id') for fact in values} == expected_ids, 'Unexpected source identity')
        for fact in values:
            require(fact.get('subjectId') == fixture['subjectId'].lower(), 'Foreign subject evidence')
            require(fact.get('sourceEventId') == fact.get('id'), 'Unbound provenance')
            require(fact.get('source') == 'fixture:restart' and fact.get('confidence') == 0.85, 'Changed source/confidence')
            require(fact.get('basis') == 'observed' and fact.get('timeZone') == 'Europe/Paris', 'Changed observation metadata')
            require(fact.get('occurredAt') is None and fact.get('observedAt') == fixture['observedAt'], 'Changed occurrence/observation time')
            require(fact.get('recordedAt') == recorded[fact['id']], 'Boot replaced original recording time')
        return values

    current, historical, changes, missing = bodies
    new = facts(current, {fixture['correctionId'].lower()})[0]
    old = facts(historical, {fixture['firstId'].lower()})[0]
    require(new.get('locationId') == fixture['correctedLocationId'].lower(), 'Correction was not restored')
    require(old.get('locationId') == fixture['originalLocationId'].lower(), 'Historical knowledge was not restored')
    require(current.get('status') == historical.get('status') == 'evidence', 'Location evidence missing')
    require(current.get('uncertainty') == historical.get('uncertainty') == [], 'Recovered projection remains incomplete')
    facts(changes, {event['id'].lower() for event in fixture['sourceEvents']})
    values = changes.get('changes', [])
    require(len(values) == 2 and changes.get('next') is None and changes.get('projectionBehind') is False, 'Change response is incomplete')
    correction = [change for change in values if change.get('id') == fixture['correctionId'].lower()]
    require(len(correction) == 1 and correction[0].get('kind') == 'correction', 'Replaced assertion lost its correction')
    require(set(correction[0].get('supportingEventIds', [])) == {fixture['firstId'].lower(), fixture['correctionId'].lower()}, 'Correction evidence changed')
    require(missing.get('status') == 'no_evidence' and missing.get('facts') == [] and missing.get('entityId') == fixture['missingId'].lower(), 'Unknown state fabricated a location')
    require(missing.get('uncertainty') == ['noEvidence'], 'Unknown-state uncertainty was hidden')


def comparison_guards(bodies, fixture):
    for variant in range(7):
        altered = copy.deepcopy(bodies)
        if variant == 0:
            altered[0]['facts'] = []
        elif variant == 1:
            altered[0]['facts'][0]['locationId'] = fixture['originalLocationId'].lower()
        elif variant == 2:
            altered[0]['facts'][0]['sourceEventId'] = fixture['foreignEventId'].lower()
        elif variant == 3:
            altered[0]['facts'][0]['observedAt'] = '2099-01-01T00:00:00.000000Z'
        elif variant == 4:
            altered[0]['facts'][0]['confidence'] = 0
        elif variant == 5:
            altered[2]['facts'] = []
        else:
            altered[0]['actorId'] = fixture['foreignActorId'].lower()
        try:
            validate_bodies(altered, fixture)
        except RuntimeError:
            continue
        raise RuntimeError('Comparison accepted corrupted evidence')


def start(binary, env):
    process = subprocess.Popen([str(binary), 'serve'], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            require(process.poll() is None, 'Server exited before binding')
            if not selector.select(timeout=0.25):
                continue
            line = process.stdout.readline(4097)
            require(len(line) <= 4096, 'Unexpected oversized server output')
            match = re.fullmatch(r'SQUIDRA listening 127\.0\.0\.1:(\d+)\n', line)
            if match:
                port = int(match.group(1))
                require(1 <= port <= 65535, 'Invalid owned listener port')
                return process, port
        raise RuntimeError('Server startup deadline exceeded')
    except BaseException:
        cleanup(process)
        raise
    finally:
        selector.close()


def cleanup(process):
    if process is None:
        return
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    if process.stdout:
        process.stdout.close()


def stop(process, stop_signal):
    process.send_signal(stop_signal)
    require(process.wait(timeout=10) == 0, 'Owned server did not shut down cleanly')
    if process.stdout:
        process.stdout.close()


def read(port, fixture, env, request_ids):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
    try:
        for probe in ['/health/live', '/health/ready']:
            connection.request('GET', probe)
            response = connection.getresponse()
            require(response.status == 200, 'Restarted server probe failed')
            require(len(response.read(4097)) <= 4096, 'Oversized probe response')
        bodies = []
        spoofed = str(uuid.uuid4())
        for query in fixture['requests']:
            require(query['path'] in ['/api/v1/world/location', '/api/v1/world/changes'], 'Unexpected fixture endpoint')
            payload = query['body'].encode()
            require(len(payload) <= 4096, 'Oversized fixture request')
            connection.request('POST', query['path'], body=payload, headers={
                'Authorization': 'Bearer ' + env['SQUIDRA_AUTH_TOKEN'], 'Content-Type': 'application/json',
                'Origin': env['SQUIDRA_UI_ORIGIN'], 'X-Request-ID': spoofed,
            })
            response = connection.getresponse()
            require(response.status == 200, 'World read failed after server startup')
            require(response.getheader('Cache-Control') == 'no-store', 'World response became cacheable')
            request_id = str(uuid.UUID(response.getheader('X-Request-ID', '')))
            require(request_id != spoofed and request_id not in request_ids, 'Transport request identity was reused')
            request_ids.add(request_id)
            raw = response.read(1_048_577)
            require(len(raw) <= 1_048_576, 'Oversized world response')
            bodies.append(json.loads(raw))
        validate_bodies(bodies, fixture)
        return bodies
    finally:
        connection.close()


def main():
    credential_path, port = sys.argv[1:3]
    require(port.isdecimal() and 1 <= int(port) <= 65535, 'Invalid isolated database port')
    credentials = dict(line.split('=', 1) for line in Path(credential_path).read_text().splitlines())
    env = dict(os.environ, SQUIDRA_TEST_DB_PORT=port, SQUIDRA_TEST_DB_PASSWORD=credentials['POSTGRES_PASSWORD'])
    subprocess.run(['swift', 'build', '--product', 'squidra', '--force-resolved-versions'], check=True, timeout=300)
    location = subprocess.run(['swift', 'build', '--show-bin-path'], check=True, capture_output=True, text=True, timeout=60)
    binary = Path(location.stdout.strip()) / 'squidra'
    require(binary.is_file(), 'Built server executable missing')
    first = second = None
    with tempfile.TemporaryDirectory(prefix='squidra-restart-') as directory:
        descriptor = Path(directory) / 'fixture.json'
        env['SQUIDRA_RESTART_DESCRIPTOR_PATH'] = str(descriptor)

        def suite(name):
            subprocess.run(['bash', 'Scripts/test-issue.sh', name], env=env, check=True, timeout=300)

        try:
            suite('SQD-025-SEED')
            fixture = json.loads(descriptor.read_text())
            require(fixture['schemaVersion'] == '1', 'Unsupported restart fixture')
            passed('restart_fixture_seeded')
            env.update(SQUIDRA_PORT='0', SQUIDRA_PROFILE='offline', SQUIDRA_AUTH_TOKEN=secrets.token_hex(32),
                       SQUIDRA_ACTOR_ID=fixture['actorId'], SQUIDRA_UI_ORIGIN='http://localhost:3000',
                       SQUIDRA_DB_PORT=port, SQUIDRA_DB_USER='squidra', SQUIDRA_DB_PASSWORD=credentials['POSTGRES_PASSWORD'], SQUIDRA_DB_NAME='squidra')
            request_ids = set()
            first, first_port = start(binary, env)
            before = read(first_port, fixture, env, request_ids)
            baseline = Path(directory) / 'baseline.json'
            with os.fdopen(os.open(baseline, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as file:
                file.write(canonical(before))
            passed('first_process_read')
            comparison_guards(before, fixture)
            passed('restart_comparison_guards')
            stop(first, signal.SIGTERM)
            passed('first_process_shutdown')
            suite('SQD-025-RESET')
            passed('projection_cache_cleared')
            second, second_port = start(binary, env)
            after = read(second_port, fixture, env, request_ids)
            expected = baseline.read_bytes()
            require(canonical(after) == expected, 'Structured evidence changed after process restart/cache rebuild')
            require(len(request_ids) == 8, 'Two actual response sets were not observed')
            print('Restart canonical evidence SHA256: ' + hashlib.sha256(expected).hexdigest(), flush=True)
            passed('second_process_rebuilt_same_evidence')
            suite('SQD-025-VERIFY')
            passed('restart_database_verified')
            stop(second, signal.SIGINT)
            passed('second_process_shutdown')
        finally:
            cleanup(first)
            cleanup(second)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        detail = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print('Restart qualification failed: ' + detail, file=sys.stderr)
        raise SystemExit(1)
