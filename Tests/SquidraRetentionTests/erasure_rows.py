"""Real SQL transactional account erasure in an owned, network-isolated fixture."""
import json, os, secrets, subprocess, tempfile, time, uuid
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
ENGINE = os.environ.get('SQUIDRA_CONTAINER_ENGINE', 'docker')
name = 'squidra-erasure-' + uuid.uuid4().hex[:12]
nonce = uuid.uuid4().hex
identity = None

def engine(*args, **kwargs):
    return subprocess.run([ENGINE,*args],capture_output=True,check=True,timeout=120,**kwargs)
def command():
    return [ENGINE,'exec','-i',identity,'psql','-X','-A','-t','-q','-v','ON_ERROR_STOP=1','-U','squidra','-d','squidra']
def sql(query, ok=True):
    r=subprocess.run(command(),input=query.encode(),capture_output=True,timeout=30)
    if (r.returncode==0)!=ok:
        print(r.stderr.decode()[:3000])
        raise AssertionError('Unexpected fixture SQL outcome')
    return r.stdout.decode().strip()
def sleeping(app):
    end=time.monotonic()+10
    while time.monotonic()<end:
        if sql(f"SELECT count(*) FROM pg_stat_activity WHERE application_name='{app}' AND wait_event='PgSleep'")=='1': return
        time.sleep(.05)
    raise AssertionError('Concurrent SQL handle did not reach synchronization point')
a='00000000-0000-0000-0000-000000000001'
b='00000000-0000-0000-0000-000000000002'
def insert(actor):
    return f"INSERT INTO world_entities(id,actor_id,kind) VALUES(gen_random_uuid(),'{actor}','fixture');"
try:
    with tempfile.TemporaryDirectory() as folder:
        creds=Path(folder)/'env';creds.touch(mode=0o600);creds.write_text('POSTGRES_DB=squidra\nPOSTGRES_USER=squidra\nPOSTGRES_PASSWORD='+secrets.token_urlsafe(32)+'\n')
        identity=engine('create','--name',name,'--network','none','--label','io.squidra.database=test','--label','io.squidra.fence-test='+nonce,'--env-file',str(creds),'--tmpfs','/var/lib/postgresql/data:rw,nosuid,size=1g','localhost/squidra-postgres:17-postgis3.6.4-vector0.8.7').stdout.decode().strip()
        engine('start',identity)
        for _ in range(60):
            if subprocess.run([ENGINE,'exec',identity,'pg_isready','-U','squidra','-d','squidra'],capture_output=True).returncode==0: break
            time.sleep(.25)
        else: raise AssertionError('Readiness failed')
        subprocess.run(['bash','Scripts/dev-db.sh','migrate'],cwd=ROOT,env=dict(os.environ,SQUIDRA_DB_CONTAINER=name,SQUIDRA_CONTAINER_ENGINE=ENGINE),capture_output=True,check=True,timeout=120)
        for filename in ('world.sql','runtime.sql'):
            fixture=(ROOT/'Tests/SquidraPostgresTests'/filename).read_text()
            assert fixture.endswith('ROLLBACK;\n')
            sql(fixture[:-len('ROLLBACK;\n')]+'COMMIT;\n')
        sql((ROOT/'Tests/SquidraRetentionTests/erasure_rows.sql').read_text())
        tables=sql("SELECT table_name FROM information_schema.columns WHERE table_schema='public' AND column_name='actor_id' AND table_name NOT IN ('account_erasure_fences','account_database_erasure_receipts') ORDER BY table_name").splitlines()
        assert len(tables)==27
        def snapshot(actor):
            return {table:sql(f"SELECT row_to_json(t)::text FROM {table} t WHERE actor_id='{actor}' ORDER BY row_to_json(t)::text") for table in tables}
        before=snapshot(a); other=snapshot(b)
        assert all(before.values()), 'Every table must contain an actor fixture'
        sql(f"SELECT erase_fenced_account_rows('{a}',repeat('a',64))",False)
        sql(f"SELECT fence_account_for_erasure('{a}')")
        # Fence alone must never allow journal or media deletion.
        for table in ('world_events','retained_media','consolidation_journals','read_run_local_domains','action_ledger'):
            sql(f"DELETE FROM {table} WHERE actor_id='{a}'",False)
        # Unknown actor-owned tables fail closed, including an empty table.
        sql('CREATE TABLE erasure_future_probe(actor_id uuid)')
        sql(f"SELECT erase_fenced_account_rows('{a}',repeat('a',64))",False)
        sql('DROP TABLE erasure_future_probe')
        # A late database failure must roll back every preceding deletion and receipt.
        sql("CREATE FUNCTION refuse_fixture_delete() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture'; END $$; CREATE TRIGGER fixture_failure BEFORE DELETE ON coordinate_frames FOR EACH ROW EXECUTE FUNCTION refuse_fixture_delete();")
        sql(f"SELECT erase_fenced_account_rows('{a}',repeat('a',64))",False)
        assert snapshot(a)==before and snapshot(b)==other
        assert sql('SELECT count(*) FROM account_database_erasure_receipts')=='0'
        sql('DROP TRIGGER fixture_failure ON coordinate_frames; DROP FUNCTION refuse_fixture_delete();')
        receipt=sql(f"SELECT erase_fenced_account_rows('{a}',repeat('a',64))")
        assert str(uuid.UUID(receipt))==receipt
        assert not any(snapshot(a).values()) and snapshot(b)==other
        assert sql(f"SELECT erase_fenced_account_rows('{a}',repeat('a',64))")==receipt
        assert sql(f"SELECT complete FROM account_database_erasure_receipts WHERE actor_id='{a}'")=='t'
        sql(f"UPDATE account_database_erasure_receipts SET complete=false WHERE actor_id='{a}'",False)
        sql(f"DELETE FROM account_database_erasure_receipts WHERE actor_id='{a}'",False)
        assert sql(f"SELECT account_erasure_delete_allowed('{a}')")=='f'
        sql(insert(a),False)
        sql(f"DELETE FROM world_events WHERE actor_id='{b}'",False)
        print('SQUIDRA_TEST_PASS:account_database_erasure')
finally:
    if identity:
        info=json.loads(engine('inspect',identity).stdout)[0]
        assert info['Config']['Labels'].get('io.squidra.fence-test')==nonce
        engine('rm','-f',name)
