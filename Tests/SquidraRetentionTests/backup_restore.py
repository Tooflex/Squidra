#!/usr/bin/env python3
"""Actual PostgreSQL restore qualification, exclusively in an owned ephemeral container."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
ENGINE = os.environ.get('SQUIDRA_CONTAINER_ENGINE', 'docker')
name = 'squidra-retention-test-' + uuid.uuid4().hex[:12]
nonce = uuid.uuid4().hex
identity = None


def engine(*args, **kwargs):
    return subprocess.run([ENGINE, *args], capture_output=True, timeout=120, check=True, **kwargs)


def sql(statement, database='squidra', succeeds=True):
    result = subprocess.run([ENGINE, 'exec', '-i', identity, 'psql', '-X', '-A', '-t', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'squidra', '-d', database], input=statement.encode(), capture_output=True, timeout=60)
    if (result.returncode == 0) != succeeds:
        raise AssertionError('Unexpected SQL outcome (content withheld)')
    return result.stdout


def utility(script, archive, succeeds=True, container=None):
    result = subprocess.run(['bash', str(ROOT / 'Scripts' / script), container or name, str(archive)], capture_output=True, timeout=180)
    if (result.returncode == 0) != succeeds:
        raise AssertionError('Unexpected utility outcome: ' + result.stdout.decode())
    return json.loads(result.stdout)


try:
    with tempfile.TemporaryDirectory(prefix='squidra-retention-') as folder:
        root = Path(folder)
        credentials = root / 'credentials'
        credentials.touch(mode=0o600)
        credentials.write_text('POSTGRES_DB=squidra\nPOSTGRES_USER=squidra\nPOSTGRES_PASSWORD=' + secrets.token_urlsafe(32) + '\n')
        identity = engine('create', '--name', name, '--label', 'io.squidra.database=test', '--label', 'io.squidra.retention-test=' + nonce, '--network', 'none', '--env-file', str(credentials), '--tmpfs', '/var/lib/postgresql/data:rw,nosuid,size=1g', 'localhost/squidra-postgres:17-postgis3.6.4-vector0.8.7').stdout.decode().strip()
        engine('start', identity)
        for attempt in range(60):
            probe = subprocess.run([ENGINE, 'exec', identity, 'pg_isready', '-U', 'squidra', '-d', 'squidra'], capture_output=True)
            if probe.returncode == 0:
                break
            time.sleep(0.25)
        else:
            raise AssertionError('Database readiness timeout')
        env = dict(os.environ, SQUIDRA_DB_CONTAINER=name, SQUIDRA_CONTAINER_ENGINE=ENGINE)
        subprocess.run(['bash', 'Scripts/dev-db.sh', 'migrate'], cwd=ROOT, env=env, capture_output=True, check=True, timeout=120)
        fixture = (ROOT / 'Tests/SquidraPostgresTests/world.sql').read_text()
        assert fixture.endswith('ROLLBACK;\n')
        sql(fixture[:-len('ROLLBACK;\n')] + 'COMMIT;\n')
        sql("INSERT INTO agent_runs(id,actor_id,state,version,trace_id) VALUES('70000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','COMPLETED',7,'80000000-0000-0000-0000-000000000001');")
        tables = ['squidra_schema_migrations', 'coordinate_frames', 'world_entities', 'observations', 'world_events', 'world_event_entities', 'spatial_facts', 'projection_versions', 'agent_runs']
        def snapshot(db):
            return {table: sql(f"SELECT row_to_json(t)::text FROM {table} t ORDER BY row_to_json(t)::text", db) for table in tables}
        before = snapshot('squidra')
        assert all(before.values())
        archive = root / 'backup.dump'
        assert utility('backup.sh', archive)['status'] == 'backed_up'
        assert archive.stat().st_mode & 0o777 == 0o600
        original = archive.read_bytes()
        utility('backup.sh', archive, succeeds=False)
        assert archive.read_bytes() == original
        print('SQUIDRA_TEST_PASS:private_no_overwrite')
        restored = utility('restore.sh', archive)['database']
        assert snapshot(restored) == before
        assert snapshot('squidra') == before
        assert sql('SELECT version FROM agent_runs', restored).strip() == b'7'
        assert sql('SELECT max(stream_version) FROM world_events', restored).strip() == b'2'
        print('SQUIDRA_TEST_PASS:facts_versions_restored')
        sql('DELETE FROM world_events', restored, succeeds=False)
        sql('TRUNCATE world_event_entities CASCADE', restored, succeeds=False)
        sql('UPDATE agent_runs SET version=8', restored, succeeds=False)
        assert snapshot(restored) == before
        print('SQUIDRA_TEST_PASS:restored_invariants')
        symlink = root / 'link.dump'
        symlink.symlink_to(archive)
        utility('restore.sh', symlink, succeeds=False)
        os.chmod(archive, 0o644)
        utility('restore.sh', archive, succeeds=False)
        os.chmod(archive, 0o600)
        invalid = root / 'invalid.dump'
        invalid.touch(mode=0o600)
        invalid.write_bytes(b'PGDMPbroken-truncated-archive')
        failure = utility('restore.sh', invalid, succeeds=False)
        assert 'database_to_inspect' in failure
        assert sql("SELECT count(*) FROM pg_tables WHERE schemaname='public'", failure['database_to_inspect']).strip() == b'0'
        assert snapshot('squidra') == before
        print('SQUIDRA_TEST_PASS:unsafe_and_corrupt_rejected')
        # A genuine unrelated container must be rejected before pg_dump execution.
        foreign_name = 'squidra-foreign-test-' + uuid.uuid4().hex[:12]
        foreign = engine('create', '--name', foreign_name, '--network', 'none', '--entrypoint', '/bin/sleep', 'localhost/squidra-postgres:17-postgis3.6.4-vector0.8.7', '30').stdout.decode().strip()
        try:
            engine('start', foreign)
            utility('backup.sh', root / 'foreign.dump', succeeds=False, container=foreign_name)
            assert not (root / 'foreign.dump').exists()
        finally:
            engine('rm', '-f', foreign)
        print('SQUIDRA_TEST_PASS:unowned_container_rejected')
finally:
    if identity:
        info = json.loads(engine('inspect', identity).stdout)[0]
        if info['Config']['Labels'].get('io.squidra.retention-test') != nonce:
            raise AssertionError('Container ownership mismatch; refusing removal')
        engine('rm', '-f', identity)
