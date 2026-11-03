"""Real SQL admission/erasure races in an owned, network-isolated fixture."""
import json, os, secrets, subprocess, tempfile, time, uuid
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
ENGINE = os.environ.get('SQUIDRA_CONTAINER_ENGINE', 'docker')
name = 'squidra-fence-' + uuid.uuid4().hex[:12]
nonce = uuid.uuid4().hex
identity = None

def engine(*args, **kwargs):
    return subprocess.run([ENGINE,*args],capture_output=True,check=True,timeout=120,**kwargs)
def command():
    return [ENGINE,'exec','-i',identity,'psql','-X','-A','-t','-q','-v','ON_ERROR_STOP=1','-U','squidra','-d','squidra']
def sql(query, ok=True):
    r=subprocess.run(command(),input=query.encode(),capture_output=True,timeout=30)
    assert (r.returncode==0)==ok, 'Unexpected SQL outcome; contents withheld'
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
        assert sql("SELECT count(*) FROM information_schema.columns c WHERE c.table_schema='public' AND c.column_name='actor_id' AND c.table_name NOT IN ('account_erasure_fences','account_database_erasure_receipts') AND NOT EXISTS(SELECT 1 FROM pg_trigger t WHERE t.tgrelid=('public.'||c.table_name)::regclass AND t.tgname='account_write_admission')")=='0'
        assert sql("SELECT count(*) FROM pg_trigger WHERE tgname='account_write_admission'")=='27'
        sql(insert(a)+insert(b))
        sql(f"BEGIN; SELECT fence_account_for_erasure('{a}'); ROLLBACK;")
        sql(insert(a))
        sql(f"SELECT fence_account_for_erasure('{a}');")
        sql(insert(a),False);sql(insert(b))
        sql(f"UPDATE world_entities SET kind='changed' WHERE actor_id='{a}'",False)
        sql(f"UPDATE world_entities SET actor_id='{a}' WHERE actor_id='{b}'",False)
        sql(f"UPDATE account_erasure_fences SET erased=false WHERE actor_id='{a}'",False)
        sql(f"DELETE FROM account_erasure_fences WHERE actor_id='{a}'",False)
        sql('TRUNCATE account_erasure_fences',False)
        sql(f"SELECT fence_account_for_erasure('{a}');")
        # Committed existing write holds the admission row until transaction end.
        c=str(uuid.uuid4())
        p=subprocess.Popen(command(),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        p.stdin.write(("SET application_name='fence_admitted'; BEGIN; "+insert(c)+"SELECT pg_sleep(3); COMMIT;").encode());p.stdin.close()
        sleeping('fence_admitted')
        sql(f"SELECT fence_account_for_erasure('{c}')")
        assert p.wait(timeout=10)==0
        sql(insert(c),False)
        # A stale repeatable-read snapshot cannot miss a later committed fence.
        c=str(uuid.uuid4());sql(insert(c))
        p=subprocess.Popen(command(),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        p.stdin.write(("SET application_name='fence_stale'; BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT count(*) FROM account_erasure_fences; SELECT pg_sleep(3); "+insert(c)+"COMMIT;").encode());p.stdin.close()
        sleeping('fence_stale');sql(f"SELECT fence_account_for_erasure('{c}')")
        assert p.wait(timeout=10)!=0
        assert b'could not serialize access' in p.stderr.read()
        print('SQUIDRA_TEST_PASS:account_erasure_fence')
finally:
    if identity:
        info=json.loads(engine('inspect',identity).stdout)[0]
        assert info['Config']['Labels'].get('io.squidra.fence-test')==nonce
        engine('rm','-f',name)
