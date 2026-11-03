#!/usr/bin/env python3
"""Trusted single-host native account erasure. No HTTP/model entry point."""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import uuid
import decisions


@contextmanager
def quiescent(authority, actor):
    """Never unlink a lock: every native process retains SH until kernel exit."""
    actor = decisions.actor_id(actor)
    with decisions.directory(authority) as parent:
        fd = os.open(actor+'.process.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=parent)
        try:
            decisions.check_file(fd)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if os.fstat(fd).st_size != 0 or os.fstat(fd).st_nlink != 1:
                raise ValueError('Invalid process lease')
            os.fsync(fd)
            os.fsync(parent)
            yield
        finally:
            os.close(fd)


@contextmanager
def local_run_inventory(path, actor):
    """Current native storage contains only minimal ownership UUID lock files.

    Keep their identity forever. Unknown files refuse the operation; never infer
    actor ownership or delete operator input, provider keys or shared budgets.
    """
    if path is None:
        yield
        return
    with decisions.directory(path) as parent:
        target = None
        try:
            for name in os.listdir(parent):
                if not name.endswith('.lock'):
                    raise ValueError('Unqualified local run storage')
                decisions.actor_id(name[:-5])
                fd = os.open(name, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                try:
                    decisions.check_file(fd)
                    raw = os.read(fd, 38)
                    if len(raw) != 37 or raw[-1:] != b'\n':
                        raise ValueError('Invalid local ownership identity')
                    decisions.actor_id(raw[:-1].decode('ascii'))
                    if name == actor+'.lock':
                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        target, fd = fd, None
                finally:
                    if fd is not None:
                        os.close(fd)
            yield
        finally:
            if target is not None:
                os.close(target)


def execute(args):
    actor = decisions.actor_id(args.actor)
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}', args.container):
        raise ValueError('Invalid container')
    engine = os.environ.get('SQUIDRA_CONTAINER_ENGINE', 'docker')
    def run(arguments, **kwargs):
        return subprocess.run([engine, *arguments], check=True, timeout=120, stderr=subprocess.DEVNULL, **kwargs)
    info = json.loads(run(['inspect', args.container], stdout=subprocess.PIPE).stdout)[0]
    identity = info['Id']
    if (info['Config']['Labels'] or {}).get('io.squidra.database') not in ('test', 'development') or not info['State']['Running'] or not re.fullmatch(r'[a-f0-9]{64}', identity):
        raise ValueError('Unqualified database')
    # Intent remains durable if the next step is busy, fails or is interrupted.
    digest = decisions.request_erasure(args.authority, actor)
    with quiescent(args.authority, actor), local_run_inventory(args.run_directory, actor):
        command = ['exec', '-i', identity, 'psql', '-X', '-A', '-t', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'squidra', '-d', 'squidra']
        # Commit the permanent fence separately so a later deletion failure cannot
        # undo it. UUID and SHA inputs are canonical, not user-controlled SQL text.
        run(command, input=("SET statement_timeout='60s'; SET lock_timeout='5s'; SELECT fence_account_for_erasure('"+actor+"'::uuid);").encode(), stdout=subprocess.DEVNULL)
        receipt = run(command, input=("SET statement_timeout='60s'; SET lock_timeout='5s'; SELECT erase_fenced_account_rows('"+actor+"'::uuid,'"+digest+"');").encode(), stdout=subprocess.PIPE).stdout.decode().strip()
        if str(uuid.UUID(receipt)) != receipt:
            raise ValueError('Invalid database receipt')
        return {'status':'erased', 'scope':'native-single-host-v1', 'receipt_id':receipt,
                'authority_sha256':digest, 'local_payload_files':0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--authority', required=True)
    parser.add_argument('--actor', required=True)
    parser.add_argument('--container', required=True)
    storage = parser.add_mutually_exclusive_group(required=True)
    storage.add_argument('--run-directory')
    storage.add_argument('--no-local-run-directory', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(execute(args)))
        return 0
    except BlockingIOError:
        print(json.dumps({'status':'busy', 'reason':'Stop all native processes for this account, wait for exit, then retry; recorded erasure intent is retained.'}))
        return 2
    except (OSError, ValueError, TypeError, KeyError, IndexError, subprocess.SubprocessError):
        print(json.dumps({'status':'failed', 'reason':'Inspect host prerequisites and retry only after reconciliation; recorded intent/fences are retained. No completion claimed.'}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
