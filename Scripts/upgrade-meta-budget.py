#!/usr/bin/env python3
"""Explicit, locked v1 -> Spark v2 renewal. Never initializes or refunds a ledger."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat

spec = importlib.util.spec_from_file_location('budget', Path(__file__).with_name('test-meta-live.py'))
budget = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budget)


def upgrade(directory, expected_sha256):
    directory = Path(directory)
    if (not directory.is_absolute() or str(directory.resolve()) != str(directory)
            or len(expected_sha256) != 64 or any(c not in '0123456789abcdef' for c in expected_sha256)):
        raise budget.Refused('invalid_migration_input')
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise budget.Refused('invalid_private_directory')
    # Existing lock identity is required: migration cannot create a new budget.
    fd = os.open(directory / 'live-budget.lock', os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise budget.Refused('invalid_lock')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = directory / 'live-budget.json'
        raw = budget.private_file(path, 262144)
        ledger = budget.decode_ledger(raw)
        used = budget.validate(ledger)
        if ledger['schemaVersion'] == 2:
            if ledger['history']['sha256'] != expected_sha256:
                raise budget.Refused('history_mismatch')
            return used  # Retry preserves all subsequently reserved attempts.
        if hashlib.sha256(raw).hexdigest() != expected_sha256:
            raise budget.Refused('source_changed')
        upgraded = budget.upgrade_legacy_bytes(raw)
        budget.save(path, upgraded)
        return budget.validate(upgraded)
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--expected-sha256', required=True)
    args = parser.parse_args()
    used = upgrade(args.directory, args.expected_sha256)
    print(json.dumps({'schemaVersion': 2, 'reservedEURCents': used, 'authorizedEURCents': budget.CAP_CENTS,
                      'reservationIsNotMeasuredSpend': True}))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print(json.dumps({'outcome': 'refused', 'reason': 'migration_failed_original_or_complete_new_state_retained'}))
        raise SystemExit(2)
