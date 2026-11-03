#!/usr/bin/env python3
"""Explicit live probes only. Never called by CI or the offline local gate.

The task owner's authorization is 100 EUR TOTAL across Meta/SAM. Retain this
private ledger across all probes; neither failures nor estimates refund reserves.
"""
import argparse
import base64
import hashlib
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
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1 or not 0 < info.st_size <= maximum):
            raise Refused('invalid_private_file')
        return os.read(descriptor, maximum + 1)
    finally:
        os.close(descriptor)


def decode_ledger(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise Refused('duplicate_ledger_key')
            result[key] = value
        return result
    def reject_constant(_):
        raise Refused('invalid_json_number')
    try:
        return json.loads(raw, object_pairs_hook=unique, parse_constant=reject_constant)
    except (ValueError, TypeError, UnicodeError):
        raise Refused('invalid_ledger_json') from None


def initial():
    return {'schemaVersion': 1, 'authorizedEURCents': CAP_CENTS,
            'reservationEURCents': RESERVATION_CENTS, 'fx': FX,
            'validUntil': VALID_UNTIL, 'attempts': []}


def validate_legacy(ledger):
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


# Reviewed Standard Spark-only envelope. Prior attempts remain encoded verbatim.
SPARK_POLICY_ID = 'spark-standard-2026-11-03'
SPARK_RESERVATION_CENTS = 250
SPARK_VALID_UNTIL = '2026-11-05T00:00:00+00:00'
SPARK_FX = {'usdPerEUR': '1.1179', 'date': '2026-11-03', 'source': 'ECB'}
SPARK_MAXIMUM_COST_MICRO_USD = 1_500_000


def legacy_history(ledger):
    history = ledger.get('history')
    if not isinstance(history, dict) or set(history) != {'base64', 'sha256'}:
        raise Refused('invalid_history')
    try:
        raw = base64.b64decode(history['base64'], validate=True)
        if len(raw) > 262144 or base64.b64encode(raw).decode() != history['base64'] or hashlib.sha256(raw).hexdigest() != history['sha256']:
            raise ValueError()
        old = decode_ledger(raw)
        validate_legacy(old)
        return old
    except (ValueError, TypeError, KeyError, UnicodeError):
        raise Refused('invalid_history') from None


def validate(ledger):
    if isinstance(ledger, dict) and type(ledger.get('schemaVersion')) is int and ledger['schemaVersion'] == 1:
        return validate_legacy(ledger)
    if not isinstance(ledger, dict) or set(ledger) != {'schemaVersion','authorizedEURCents','policyID','fx','validUntil','history','attempts'}:
        raise Refused('invalid_ledger')
    if type(ledger['schemaVersion']) is not int or ledger['schemaVersion'] != 2 or type(ledger['authorizedEURCents']) is not int or ledger['authorizedEURCents'] != CAP_CENTS or ledger['policyID'] != SPARK_POLICY_ID or ledger['fx'] != SPARK_FX or ledger['validUntil'] != SPARK_VALID_UNTIL:
        raise Refused('invalid_ledger')
    old = legacy_history(ledger)
    used = validate_legacy(old)
    identifiers = {item['id'] for item in old['attempts']}
    attempts = ledger['attempts']
    if not isinstance(attempts, list) or len(attempts) > CAP_CENTS // SPARK_RESERVATION_CENTS:
        raise Refused('invalid_ledger')
    for item in attempts:
        if not isinstance(item, dict) or set(item) != {'id','model','reservedEURCents','status','report'} or item['model'] != MODELS['spark'] or type(item['reservedEURCents']) is not int or item['reservedEURCents'] != SPARK_RESERVATION_CENTS or item['status'] not in ('reserved','passed','failed','interrupted') or (item['report'] is not None and not isinstance(item['report'],dict)):
            raise Refused('invalid_ledger')
        try:
            if str(uuid.UUID(item['id'])) != item['id'] or item['id'] in identifiers:
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            raise Refused('invalid_ledger') from None
        identifiers.add(item['id'])
        used += SPARK_RESERVATION_CENTS
    if used > CAP_CENTS:
        raise Refused('invalid_ledger')
    return used


def policy(ledger, model):
    validate(ledger)
    if ledger['schemaVersion'] == 1:
        if model not in MODELS.values():
            raise Refused('invalid_model')
        return RESERVATION_CENTS, VALID_UNTIL
    if model != MODELS['spark']:
        raise Refused('model_not_qualified_for_policy')
    return SPARK_RESERVATION_CENTS, SPARK_VALID_UNTIL


def upgrade_legacy_bytes(raw):
    # Explicit migration only. Preserve every original byte, report and reservation.
    old = decode_ledger(raw)
    validate_legacy(old)
    upgraded = {'schemaVersion':2, 'authorizedEURCents':CAP_CENTS,
        'policyID':SPARK_POLICY_ID, 'fx':SPARK_FX.copy(), 'validUntil':SPARK_VALID_UNTIL,
        'history':{'base64':base64.b64encode(raw).decode(), 'sha256':hashlib.sha256(raw).hexdigest()},
        'attempts':[]}
    if validate(upgraded) != validate_legacy(old) or len(json.dumps(upgraded).encode()) > 262144:
        raise Refused('migration_not_representable')
    return upgraded


def reserve(ledger, model, now):
    used = validate(ledger)
    reservation, expiry = policy(ledger, model)
    if now.tzinfo is None or now >= dt.datetime.fromisoformat(expiry):
        raise Refused('pricing_or_fx_snapshot_expired')
    if model not in MODELS.values() or used + reservation > CAP_CENTS:
        raise Refused('budget_exhausted_or_invalid_model')
    item = {'id': str(uuid.uuid4()), 'model': model, 'reservedEURCents': reservation,
            'status': 'reserved', 'report': None}
    ledger['attempts'].append(item)
    return item


def save(path, ledger):
    validate(ledger)
    encoded = json.dumps(ledger, indent=2, sort_keys=True, allow_nan=False).encode()
    if len(encoded) > 262144:
        raise Refused('oversized_ledger')
    fd, temp = tempfile.mkstemp(prefix='.budget-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(encoded)
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
            ledger = decode_ledger(private_file(ledger_path, 262144))
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
