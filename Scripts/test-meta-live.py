#!/usr/bin/env python3
"""Explicit live probes only. Never called by CI or the offline local gate.

The task owner's authorization is 100 EUR TOTAL across Meta/SAM. Retain this
private ledger across all probes; neither failures nor estimates refund reserves.
"""
import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
DIRECTORY = ROOT / '.build/provider-access'
CAP_CENTS = 10000
RESERVATION_CENTS = 1000
VALID_UNTIL = '2026-11-02T00:00:00+00:00'
FX = {'usdPerEUR': '1.1172', 'date': '2026-10-30', 'source': 'ECB'}
MODELS = {'spark': 'muse-spark-1.3', 'wonder': 'muse-wonder-1.0', 'sam': 'sam-3.1'}


class Refused(Exception):
    pass


def private_file(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or not 0 < info.st_size <= maximum):
            raise Refused('invalid_private_file')
        return os.read(descriptor, maximum + 1)
    finally:
        os.close(descriptor)


def initial():
    return {'schemaVersion': 1, 'authorizedEURCents': CAP_CENTS,
            'reservationEURCents': RESERVATION_CENTS, 'fx': FX,
            'validUntil': VALID_UNTIL, 'attempts': []}


def validate(ledger):
    if not isinstance(ledger, dict) or set(ledger) != set(initial()):
        raise Refused('invalid_ledger')
    for name in ('schemaVersion', 'authorizedEURCents', 'reservationEURCents', 'fx', 'validUntil'):
        if ledger[name] != initial()[name] or type(ledger[name]) is not type(initial()[name]):
            raise Refused('invalid_ledger')
    attempts = ledger['attempts']
    if not isinstance(attempts, list) or len(attempts) > CAP_CENTS // RESERVATION_CENTS:
        raise Refused('invalid_ledger')
    identifiers = set()
    for item in attempts:
        if (not isinstance(item, dict) or set(item) != {'id', 'model', 'reservedEURCents', 'status', 'report'}
                or item['model'] not in MODELS.values()
                or type(item['reservedEURCents']) is not int or item['reservedEURCents'] != RESERVATION_CENTS
                or item['status'] not in ('reserved', 'passed', 'failed', 'interrupted')
                or (item['report'] is not None and not isinstance(item['report'], dict))):
            raise Refused('invalid_ledger')
        try:
            if str(uuid.UUID(item['id'])) != item['id'] or item['id'] in identifiers:
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            raise Refused('invalid_ledger') from None
        identifiers.add(item['id'])
    return sum(item['reservedEURCents'] for item in attempts)


def reserve(ledger, model, now):
    used = validate(ledger)
    if now.tzinfo is None or now >= dt.datetime.fromisoformat(VALID_UNTIL):
        raise Refused('pricing_or_fx_snapshot_expired')
    if model not in MODELS.values() or used + RESERVATION_CENTS > CAP_CENTS:
        raise Refused('budget_exhausted_or_invalid_model')
    item = {'id': str(uuid.uuid4()), 'model': model, 'reservedEURCents': RESERVATION_CENTS,
            'status': 'reserved', 'report': None}
    ledger['attempts'].append(item)
    return item


def save(path, ledger):
    validate(ledger)
    fd, temp = tempfile.mkstemp(prefix='.budget-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            json.dump(ledger, handle, indent=2, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-live', action='store_true')
    parser.add_argument('--model', choices=tuple(MODELS), required=True)
    parser.add_argument('--key-file', type=Path, required=True)
    args = parser.parse_args()
    if not args.allow_live:
        raise Refused('explicit_live_opt_in_required')
    # Validate the file without emitting its contents. The Swift process loads it
    # again with no-follow/owner/mode/size checks. Never put the key in argv/env.
    private_file(args.key_file, 4096)
    DIRECTORY.mkdir(parents=True, exist_ok=True)
    info = DIRECTORY.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise Refused('invalid_private_directory')
    os.chmod(DIRECTORY, 0o700)
    ledger_path = DIRECTORY / 'live-budget.json'
    lock = os.open(DIRECTORY / 'live-budget.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(lock)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise Refused('invalid_lock')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if ledger_path.exists() or ledger_path.is_symlink():
            ledger = json.loads(private_file(ledger_path, 262144))
        else:
            ledger = initial()
        validate(ledger)
        if args.model == 'sam':
            subprocess.run([sys.executable, str(ROOT / 'Scripts/test-sam-reference.py'), '--prepare'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=True)
        # Compile before reserving; no fixture execution or network inference yet.
        subprocess.run(['swift', 'build', '--product', 'squidra-meta-qualification-fixture'], cwd=ROOT,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300, check=True)
        binary_dir = subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, timeout=30).decode().strip()
        item = reserve(ledger, MODELS[args.model], dt.datetime.now(dt.timezone.utc))
        save(ledger_path, ledger)  # Durable reservation BEFORE any provider call.
        env = {name: os.environ[name] for name in ('PATH', 'HOME', 'TMPDIR') if name in os.environ}
        env.update(SQUIDRA_META_LIVE_AUTHORIZED='1', SQUIDRA_META_RESERVATION_ID=item['id'])
        try:
            result = subprocess.run([str(Path(binary_dir) / 'squidra-meta-qualification-fixture'), args.model,
                                     str(args.key_file.resolve())], cwd=ROOT, env=env, capture_output=True, timeout=40)
            if len(result.stdout) > 16384:
                raise Refused('oversized_probe_report')
            report = json.loads(result.stdout)
            if (not isinstance(report, dict) or report.get('reservationID') != item['id']
                    or report.get('model') != item['model'] or report.get('outcome') not in ('passed', 'failed')):
                raise Refused('invalid_probe_report')
            if args.model == 'sam' and result.returncode == 0 and report['outcome'] == 'passed':
                decoded = subprocess.run([sys.executable, str(ROOT / 'Scripts/test-sam-reference.py'), '--decode'],
                                         input=result.stdout, capture_output=True, timeout=10, check=False)
                if decoded.returncode != 0 or len(decoded.stdout) > 16384:
                    report['outcome'] = 'failed'
                    report['error'] = 'reference_mask_qualification_failed'
                else:
                    report = json.loads(decoded.stdout)
            item['report'] = report
            item['status'] = 'passed' if result.returncode == 0 and report['outcome'] == 'passed' else 'failed'
        except Exception:
            item['status'] = 'interrupted'
            save(ledger_path, ledger)
            raise Refused('probe_interrupted_reservation_retained') from None
        save(ledger_path, ledger)
        # Fixture has a fixed public prompt, typed errors and no provider IDs.
        print(json.dumps({'report': item['report'], 'reservedEURCentsTotal': validate(ledger),
                          'authorizedEURCents': CAP_CENTS, 'reservationIsNotMeasuredSpend': True}, sort_keys=True))
        return 0 if item['status'] == 'passed' else 1
    finally:
        os.close(lock)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Refused as error:
        print(json.dumps({'outcome': 'refused', 'reason': str(error)}))
        raise SystemExit(2)
    except Exception:
        print(json.dumps({'outcome': 'refused', 'reason': 'local_configuration_or_process_failure'}))
        raise SystemExit(2)
