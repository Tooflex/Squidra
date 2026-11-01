#!/usr/bin/env bash
# Trusted operator utility for labeled local Squidra PostgreSQL containers.
set -euo pipefail
exec python3 - "$@" <<'PY'
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import uuid

restoring = len(sys.argv) == 4 and sys.argv[1] == '--restore'
args = sys.argv[2:] if restoring else sys.argv[1:]
if len(args) != 2:
    sys.exit('Usage: bash Scripts/backup.sh CONTAINER NEW_ARCHIVE (or restore.sh CONTAINER ARCHIVE)')
container, archive = args
if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}', container):
    sys.exit('Invalid container name')
engine = os.environ.get('SQUIDRA_CONTAINER_ENGINE', 'docker')
new_db = None
owned_temp = None

def run(arguments, **kwargs):
    return subprocess.run([engine, *arguments], timeout=120, check=True, stderr=subprocess.DEVNULL, **kwargs)

try:
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
            run(command + ['pg_restore', '-U', 'squidra', '--dbname', new_db, '--exit-on-error', '--single-transaction', '--no-owner', '--no-privileges'], stdin=source, stdout=subprocess.DEVNULL)
        print(json.dumps({'status': 'restored', 'database': new_db}))
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
except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
    # Never print database values, archive contents, commands, or provider credentials.
    report = {'status': 'failed', 'reason': 'operation failed; inspect local prerequisites; no automatic retry'}
    if new_db:
        report['database_to_inspect'] = new_db
    print(json.dumps(report))
    sys.exit(1)
finally:
    if owned_temp is not None:
        os.unlink(owned_temp)
PY
