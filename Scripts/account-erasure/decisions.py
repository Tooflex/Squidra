"""Host-private monotonic deletion intent registry; never a deletion-complete receipt.

The trusted host owns this directory independently of database backups. No CLI,
HTTP route, model tool, restore promotion or account deletion is exposed here.
"""
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import uuid

LIMIT = 1_048_576


def actor_id(value):
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise ValueError('Canonical actor UUID required')
    return value


def validate(data):
    if not isinstance(data, dict) or set(data) != {'schemaVersion', 'actors'} or type(data['schemaVersion']) is not int or data['schemaVersion'] != 1:
        raise ValueError('Invalid deletion authority')
    actors = data['actors']
    if not isinstance(actors, list) or actors != sorted(set(actor_id(x) for x in actors)):
        raise ValueError('Invalid actor inventory')
    return data


def encode(data):
    raw = (json.dumps(validate(data), sort_keys=True, separators=(',', ':')) + '\n').encode()
    if len(raw) > LIMIT:
        raise ValueError('Deletion authority capacity exceeded')
    return raw


def check_file(fd):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
        raise ValueError('Private owned regular file required')


@contextmanager
def directory(path):
    path = Path(path)
    if not path.is_absolute() or path.resolve() != path:
        raise ValueError('Canonical independent directory required')
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('Private owned directory required')
        yield fd
    finally:
        os.close(fd)


@contextmanager
def locked(fd):
    lock = os.open('authority.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    try:
        check_file(lock)
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield
    finally:
        os.close(lock)


def read(fd):
    source = os.open('decisions.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    with os.fdopen(source, 'rb') as stream:
        check_file(stream.fileno())
        raw = stream.read(LIMIT + 1)
    if len(raw) > LIMIT:
        raise ValueError('Oversized deletion authority')
    # Require canonical serialization, rejecting duplicate fields and silent repairs.
    data = validate(json.loads(raw))
    if encode(data) != raw:
        raise ValueError('Noncanonical deletion authority')
    return data


def publish(fd, data, initial=False):
    temporary = '.pending-' + uuid.uuid4().hex
    out = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    try:
        with os.fdopen(out, 'wb') as stream:
            stream.write(encode(data))
            stream.flush()
            os.fsync(stream.fileno())
        if initial:
            os.link(temporary, 'decisions.json', src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
            os.unlink(temporary, dir_fd=fd)
        else:
            os.replace(temporary, 'decisions.json', src_dir_fd=fd, dst_dir_fd=fd)
        os.fsync(fd)
    finally:
        try:
            os.unlink(temporary, dir_fd=fd)
        except FileNotFoundError:
            pass


def initialize(path):
    """Explicit provisioning only; refuses an existing registry instead of resetting it."""
    with directory(path) as fd, locked(fd):
        publish(fd, {'schemaVersion': 1, 'actors': []}, initial=True)


def snapshot(path):
    """Missing/corrupt authority fails; digest binds evidence, not freshness."""
    with directory(path) as fd, locked(fd):
        data = read(fd)
        return {'actors': tuple(data['actors']), 'sha256': hashlib.sha256(encode(data)).hexdigest()}


def request_erasure(path, actor):
    """Record intent durably before any side effect; does not claim completed erasure."""
    actor = actor_id(actor)
    with directory(path) as fd, locked(fd):
        data = read(fd)
        if actor not in data['actors']:
            data['actors'] = sorted([*data['actors'], actor])
            publish(fd, data)
        return hashlib.sha256(encode(data)).hexdigest()
