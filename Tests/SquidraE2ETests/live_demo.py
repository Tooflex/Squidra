"""Explicit historical Meta qualification; never imported by offline profiles."""
from datetime import datetime, timezone, timedelta
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import time


def admission(module, ledger, consent, now):
    if consent != '1':
        raise RuntimeError('Explicit historical cloud consent required')
    used = module.validate(ledger)
    reservation, valid_until = module.policy(ledger, module.MODELS["spark"])
    expiry = datetime.fromisoformat(valid_until)
    if now.tzinfo is None or now + timedelta(seconds=420) >= expiry:
        raise RuntimeError('Qualification snapshot expired or too close to expiry')
    if used + 4 * reservation > module.CAP_CENTS:
        raise RuntimeError('Four reservations required for two historical questions')
    return used


def preflight(root):
    spec = importlib.util.spec_from_file_location('historical_budget', root / 'Scripts/test-meta-live.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    ledger = module.decode_ledger(module.private_file(root / '.build/provider-access/live-budget.json', 262144))
    return admission(module, ledger, os.environ.get('SQUIDRA_HISTORICAL_META_LIVE'), datetime.now(timezone.utc))


def execute(root, binaries, env, identity_path, scenario, evidence, out):
    # Recheck immediately before starting the normal CLI. The server separately
    # reserves every attempt under the existing locked global ledger.
    used = preflight(root)
    identity = json.loads(identity_path.read_text())
    authority_dir = Path(out).resolve() / ('authority-' + __import__('uuid').uuid4().hex)
    authority_dir.mkdir(mode=0o700)
    (authority_dir / 'authority.lock').touch(mode=0o600)
    (authority_dir / 'decisions.json').touch(mode=0o600)
    (authority_dir / 'decisions.json').write_text('{"actors":[],"schemaVersion":1}\n')
    token = secrets.token_hex(32)
    server_env = dict(env, SQUIDRA_ERASURE_AUTHORITY_DIRECTORY=str(authority_dir), SQUIDRA_PROFILE='meta-qualification', SQUIDRA_PORT='0',
        SQUIDRA_UI_ORIGIN='http://127.0.0.1:3000',
        SQUIDRA_AUTH_TOKEN=token, SQUIDRA_ACTOR_ID=identity['actor'],
        SQUIDRA_DB_PORT=env['SQUIDRA_TEST_DB_PORT'], SQUIDRA_DB_PASSWORD=env['SQUIDRA_TEST_DB_PASSWORD'],
        SQUIDRA_DB_USER='squidra', SQUIDRA_DB_NAME='squidra', SQUIDRA_META_CLOUD_CONSENT='1',
        SQUIDRA_META_MODEL='spark', SQUIDRA_META_BUDGET_POLICY='spark-standard-2026-11-03', SQUIDRA_META_ENTITY_IDS=identity['subject'].lower(),
        SQUIDRA_META_BUDGET_DIRECTORY=str(root / '.build/provider-access'),
        MODEL_API_KEY_FILE=str(root / '.build/secrets/meta-api-key'))
    log = out / 'meta-server.log'
    with log.open('w') as stream:
        server = subprocess.Popen([str(binaries / 'squidra'), 'serve'], cwd=root,
                                  env=server_env, stdout=stream, stderr=stream)
    try:
        end = time.monotonic() + 20
        while time.monotonic() < end and server.poll() is None:
            match = re.search(r'SQUIDRA listening 127\.0\.0\.1:([0-9]+)', log.read_text()[-65536:])
            if match:
                port = int(match[1])
                if not 1 <= port <= 65535:
                    raise RuntimeError('Invalid owned server port')
                break
            time.sleep(.05)
        else:
            raise RuntimeError('Owned historical server unavailable')
        # Node receives neither provider key nor its path; only loopback auth.
        client_env = {k: env[k] for k in ('PATH', 'HOME') if k in env}
        client_env.update(SQUIDRA_HISTORICAL_META_LIVE='1', SQUIDRA_DEMO_ORIGIN=f'http://127.0.0.1:{port}',
                          SQUIDRA_DEMO_TOKEN=token)
        result = subprocess.run(['node', 'Tests/SquidraE2ETests/live_demo.mjs', str(identity_path),
            str(scenario), str(evidence), str(out / 'real-model.json')], cwd=root, env=client_env,
            capture_output=True, timeout=400)
        if result.returncode != 0 or result.stdout.strip() != b'HISTORICAL_META_VERIFIED':
            raise RuntimeError('Historical Meta qualification failed; no retry')
        report = json.loads((out / 'real-model.json').read_text())
        report['reservedEURCentsBefore'] = used
        (out / 'real-model.json').write_text(json.dumps(report, indent=2) + '\n')
    finally:
        if server.poll() is None:
            server.send_signal(signal.SIGTERM)
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=10)
                raise RuntimeError('Owned server forced shutdown; qualification incomplete')
        if server.returncode != 0:
            raise RuntimeError('Owned server did not shut down cleanly')
    report['serverShutdown'] = 'clean'
    report['harnessOutcome'] = 'passed'
    (out / 'real-model.json').write_text(json.dumps(report, indent=2) + '\n')
