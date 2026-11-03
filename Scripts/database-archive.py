import json
import hashlib
import importlib.util
from contextlib import ExitStack
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
restoring = len(sys.argv) > 1 and sys.argv[1] == '--restore'
args = sys.argv[2:] if restoring else sys.argv[1:]
if len(args) != (3 if restoring else 2):
    sys.exit('Usage: bash Scripts/backup.sh CONTAINER NEW_ARCHIVE (or restore.sh CONTAINER ARCHIVE AUTHORITY_DIRECTORY)')
container, archive = args[:2]
if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}', container):
    sys.exit('Invalid container name')
engine = os.environ.get('SQUIDRA_CONTAINER_ENGINE', 'docker')
new_db = None
owned_temp = None
resources = ExitStack()

def run(arguments, **kwargs):
    return subprocess.run([engine, *arguments], timeout=120, check=True, stderr=subprocess.DEVNULL, **kwargs)

try:
    if restoring:
        spec = importlib.util.spec_from_file_location('erasure_decisions', ROOT / 'Scripts/account-erasure/decisions.py')
        decisions = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(decisions)
        authority_fd = resources.enter_context(decisions.directory(args[2]))
        resources.enter_context(decisions.locked(authority_fd))
        authority = decisions.read(authority_fd)
        digest = hashlib.sha256(decisions.encode(authority)).hexdigest()
    info = json.loads(run(['inspect', container], stdout=subprocess.PIPE).stdout)[0]
    if (info['Config']['Labels'] or {}).get('io.squidra.database') not in ('test', 'development'):
        raise ValueError('unowned container')
    identity = info['Id']
    if not re.fullmatch(r'[a-f0-9]{64}', identity) or not info['State']['Running']:
        raise ValueError('unavailable container')
    command = ['exec', '-i', identity]
    if restoring:
        # Archive is trusted operator input: pg_restore can execute SQL from it.
        fd = os.open(archive, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb', buffering=0) as source:
            meta = os.fstat(source.fileno())
            if not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.getuid() or meta.st_mode & 0o077 or meta.st_nlink != 1:
                raise ValueError('archive must be private and owned')
            if source.read(5) != b'PGDMP':
                raise ValueError('not a custom archive')
            source.seek(0)
            new_db = 'squidra_restore_' + uuid.uuid4().hex
            run(command + ['createdb', '-U', 'squidra', '--template=template0', new_db], stdout=subprocess.DEVNULL)
            run(command + ['psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'squidra', '-d', 'postgres'],
                input=f'REVOKE CONNECT ON DATABASE {new_db} FROM PUBLIC;'.encode(), stdout=subprocess.DEVNULL)
            run(command + ['pg_restore', '-U', 'squidra', '--dbname', new_db, '--exit-on-error', '--single-transaction', '--no-owner', '--no-privileges'], stdin=source, stdout=subprocess.DEVNULL)
        # This fresh database has no application workers. Retain the authority lock
        # through reconciliation so no concurrently recorded decision is omitted.
        sql_command = command + ['psql', '-X', '-A', '-t', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'squidra', '-d', new_db]
        actual = json.loads(run(sql_command, input=b"SELECT coalesce(json_agg(json_build_array(namespace,version,checksum)), '[]'::json) FROM squidra_schema_migrations;", stdout=subprocess.PIPE).stdout)
        expected = [[namespace, path.name, hashlib.sha256(path.read_bytes()).hexdigest()]
                    for namespace in ('world', 'runtime') for path in (ROOT / 'Migrations' / namespace).glob('*.sql')]
        if sorted(actual) != sorted(expected):
            raise ValueError('restored schema requires operator migration before reconciliation')
        # --no-privileges intentionally omits source ACLs. Re-establish the narrow
        # administrative boundary explicitly for this same-role recovery profile.
        statements = ["BEGIN; SET LOCAL statement_timeout='60s'; SET LOCAL lock_timeout='5s';",
            "REVOKE ALL ON FUNCTION fence_account_for_erasure(uuid) FROM PUBLIC;",
            "REVOKE ALL ON FUNCTION erase_fenced_account_rows(uuid,text) FROM PUBLIC;",
            "REVOKE ALL ON account_database_erasure_receipts FROM PUBLIC;"]
        for actor in authority['actors']:
            # Both values are validated canonical UUID/hex, never free-form SQL.
            statements.append(f"SELECT fence_account_for_erasure('{actor}'::uuid);")
            statements.append(f"SELECT erase_fenced_account_rows('{actor}'::uuid,'{digest}');")
        statements.append('COMMIT;')
        run(sql_command, input='\n'.join(statements).encode(), stdout=subprocess.DEVNULL)
        print(json.dumps({'status': 'restored', 'database': new_db,
                          'erasure_authority_sha256': digest,
                          'reconciled_actor_count': len(authority['actors'])}))
    else:
        target = Path(archive).absolute()
        # No overwrite, including a dangling link. Create private sibling on same filesystem.
        if os.path.lexists(target):
            raise ValueError('archive already exists')
        fd, owned_temp = tempfile.mkstemp(prefix='.squidra-backup-', dir=target.parent)
        with os.fdopen(fd, 'wb') as output:
            run(command + ['pg_dump', '-U', 'squidra', '--dbname', 'squidra', '--format=custom', '--no-owner', '--no-privileges'], stdout=output)
            output.flush()
            os.fsync(output.fileno())
        os.link(owned_temp, target)  # atomic publication, refuses a concurrent existing path
        os.unlink(owned_temp)
        owned_temp = None
        directory = os.open(target.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        print('{"status":"backed_up"}')
except (OSError, ValueError, TypeError, KeyError, IndexError, subprocess.SubprocessError):
    # Never print database values, archive contents, commands, or provider credentials.
    report = {'status': 'failed', 'reason': 'operation failed; inspect local prerequisites; no automatic retry'}
    if new_db:
        report['database_to_inspect'] = new_db
    print(json.dumps(report))
    sys.exit(1)
finally:
    resources.close()
    if owned_temp is not None:
        os.unlink(owned_temp)
