#!/usr/bin/env python3
"""Execute offline release invariants; a passing gate is not release approval."""
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SUITES = [
    ('T09-REPORT-CONTRACTS', 'report_contracts'),
    ('SQD-009', 'approval_invariants'),
    ('SQD-007', 'idempotency_invariants'),
    ('T14-RUN', 'runtime_contracts'),
    ('SQD-028', 'crash_recovery'),
    ('SQD-031', 'annotated_evaluations'),
    ('T09-LATENCY-CONTRACTS', 'latency_contracts'),
    ('T09-LATENCY', 'offline_latency'),
    ('T08-FAKE-MODEL', 'historical_demo'),
    ('SQD-035', 'security_gates'),
]
FIELDS = {'issue', 'selected', 'passed', 'failed', 'skipped', 'not_executed', 'status'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def validate_summary(value, suite):
    if not isinstance(value, dict) or set(value) != FIELDS or value['issue'] != suite:
        raise ValueError('Unexpected suite report')
    for key in ['selected', 'passed', 'failed', 'skipped', 'not_executed']:
        if type(value[key]) is not int or value[key] < 0:
            raise ValueError('Invalid suite count')
    if (value['status'] != 'passed' or value['selected'] == 0
            or value['passed'] != value['selected']
            or any(value[k] for k in ['failed', 'skipped', 'not_executed'])):
        raise ValueError('Incomplete suite execution')
    return value


def validate_execution(code, stdout, stored, suite, kind="command", xml=None):
    if code != 0:
        raise ValueError('Suite command failed')
    report = validate_summary(json.loads(stored), suite)
    if kind == 'command':
        lines = stdout.splitlines()
        if not lines or report != validate_summary(json.loads(lines[-1]), suite):
            raise ValueError('Suite output and saved report differ')
    elif kind == 'xctest':
        if xml is None:
            raise ValueError('Missing XCTest evidence')
        cases = ET.fromstring(xml).findall('.//testcase')
        identities = [(case.get('classname'), case.get('name')) for case in cases]
        if (len(cases) != report['selected'] or len(set(identities)) != len(cases)
                or any(not all(identity) for identity in identities)
                or any(case.find(tag) is not None for case in cases for tag in ['failure', 'error', 'skipped'])):
            raise ValueError('Incomplete or duplicate XCTest evidence')
    else:
        raise ValueError('Unsupported suite kind')
    return report


def source_state(root=ROOT):
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=root)
    files = git('ls-files', '-z').split(b'\0')
    hashes = {}
    for raw in files:
        if not raw:
            continue
        name = os.fsdecode(raw)
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Tracked source is missing or unsafe')
        hashes[name] = digest(path.read_bytes())
    if not hashes:
        raise ValueError('Empty source inventory')
    return {'commit': git('rev-parse', 'HEAD').decode().strip(),
            'dirty': bool(git('status', '--porcelain')),
            'files_sha256': hashes,
            'inventory_sha256': digest(json.dumps(hashes, sort_keys=True, separators=(',', ':')).encode())}


def require_same_source(before, after):
    if before != after or before['dirty']:
        raise ValueError('Release gate requires unchanged clean tracked sources')


def main():
    if sys.argv[1:] not in [[], ['--profile=offline']]:
        raise SystemExit('Only --profile=offline is supported; no checks executed')
    base = ROOT / '.build/release-checks'
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (base / 'active.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('Another release invariant gate is active')
        out = base / uuid.uuid4().hex
        out.mkdir(mode=0o700)
        report = {'schemaVersion': 1, 'startedAtUTC': datetime.now(timezone.utc).isoformat(),
                  'gateStatus': 'running', 'releaseStatus': 'not_ready', 'profile': 'offline',
                  'platform': {'system': platform.system(), 'release': platform.release(), 'machine': platform.machine()},
                  'limitations': ['Fixture-scoped assertions; suite counts are not domain event counts or production guarantees.',
                                  'No new real-provider qualification; no hosted CI qualification.',
                                  'Scripted runtime latency and model-port overhead do not measure full tool-free product, HTTP or real model latency.',
                                  'Full issue 45 dependencies and human epic acceptance remain unverified.'],
                  'steps': [{'suite': s, 'marker': m, 'status': 'not_executed'} for s, m in SUITES]}
        def save():
            (out / 'report.json').write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
        save()
        try:
            before = source_state()
            require_same_source(before, before)
            report['source'] = before
            manifest = json.loads((ROOT / 'Scripts/issue-tests.json').read_text())
            # Preserve tools' ordinary runtime configuration, never provider credentials/opt-ins.
            allowed = {'PATH', 'HOME', 'TMPDIR', 'TMP', 'TEMP', 'LANG', 'LC_ALL', 'USER', 'CI',
                       'SSL_CERT_FILE', 'SQUIDRA_CONTAINER_ENGINE', 'PLAYWRIGHT_BROWSERS_PATH'}
            env = {k: v for k, v in os.environ.items() if k in allowed}
            for step in report['steps']:
                suite = step['suite']
                directory = ROOT / '.build/issue-tests' / suite
                summary = directory / 'summary.json'
                summary.unlink(missing_ok=True)
                xml = directory / 'results.xml'
                xml.unlink(missing_ok=True)
                step['status'] = 'running'
                save()
                print('Running release gate ' + suite, flush=True)
                start = time.monotonic()
                result = subprocess.run(['bash', 'Scripts/test-issue.sh', suite], cwd=ROOT, env=env, capture_output=True)
                step.update(exitCode=result.returncode, wallSeconds=round(time.monotonic()-start, 6))
                log = result.stdout + b'\n' + result.stderr
                (out / (suite + '.log')).write_bytes(log)
                step['logSHA256'] = digest(log)
                step['status'] = 'failed'
                if summary.exists():
                    shutil.copyfile(summary, out / (suite + '.summary.json'))
                step['counts'] = validate_execution(result.returncode, result.stdout.decode(), summary.read_bytes(), suite, manifest[suite]['kind'], xml.read_bytes() if xml.exists() else None)
                if xml.exists():
                    shutil.copyfile(xml, out / (suite + '.xml'))
                    step['xmlSHA256'] = digest(xml.read_bytes())
                if suite == 'T09-LATENCY':
                    directories=[]
                    for line in result.stdout.decode().splitlines():
                        if line.startswith('{'):
                            candidate=json.loads(line)
                            if isinstance(candidate,dict) and 'evidence_directory' in candidate:
                                directories.append(Path(candidate['evidence_directory']))
                    if len(directories)!=1:
                        raise ValueError('Missing latency artifact directory')
                    directory=directories[0]
                    if directory.is_symlink() or directory.resolve().parent != (ROOT/'.build/demo').resolve():
                        raise ValueError('Unexpected latency artifact directory')
                    verification=json.loads((directory/'verification.json').read_text())
                    summary_data=(directory/'latency-summary.json').read_bytes()
                    raw_data=(directory/'latency-raw.json').read_bytes()
                    summary_value=json.loads(summary_data)
                    if (verification['source_commit']!=before['commit'] or verification['source_dirty'] is not False
                            or verification['latency_summary_sha256']!=digest(summary_data)
                            or summary_value['rawSHA256']!=digest(raw_data)):
                        raise ValueError('Latency provenance mismatch')
                    from latency_metrics import evaluate
                    if evaluate(json.loads(raw_data))!=summary_value['metrics']:
                        raise ValueError('Latency statistics mismatch')
                    step['latencyMetrics']=summary_value['metrics']
                    step['latencyArtifactSHA256']={}
                    for name in ['latency-summary.json','latency-raw.json','verification.json']:
                        data=(directory/name).read_bytes()
                        (out/name).write_bytes(data)
                        step['latencyArtifactSHA256'][name]=digest(data)
                if suite == 'SQD-031':
                    step['evaluationArtifacts'] = {}
                    for profile in ['components-v1', 'world-queries-v1']:
                        source = ROOT / '.build/evals' / profile
                        result_document = json.loads((source / 'results.json').read_text())
                        if (result_document['metrics']['passed'] is not True
                                or result_document['metadata']['git_revision'] != before['commit']
                                or result_document['metadata']['worktree_dirty'] is not False):
                            raise ValueError('Evaluation provenance mismatch')
                        exports = {}
                        for filename in ['results.json', 'baseline.json', 'thresholds.json', 'predictions.json']:
                            data = (source / filename).read_bytes()
                            (out / (profile + '-' + filename)).write_bytes(data)
                            exports[filename] = digest(data)
                        step['evaluationArtifacts'][profile] = {'sha256': exports, 'metrics': result_document['metrics']}
                step['status'] = 'passed'
                save()
            require_same_source(before, source_state())
            report['gateStatus'] = 'passed'
        except (OSError, ValueError, KeyError, ET.ParseError, subprocess.SubprocessError, KeyboardInterrupt):
            report['gateStatus'] = 'failed'
            report['failure'] = 'Execution, evidence or source-integrity check failed; inspect private suite logs.'
            for step in report['steps']:
                if step['status'] == 'running':
                    step['status'] = 'failed'
        finally:
            report['finishedAtUTC'] = datetime.now(timezone.utc).isoformat()
            save()
            print(json.dumps({'report': str(out / 'report.json'), 'gateStatus': report['gateStatus'], 'releaseStatus': report['releaseStatus']}), flush=True)
        if report['gateStatus'] != 'passed':
            return 1
        # Publish markers only after the complete execution and source-integrity check.
        for step in report['steps']:
            print('SQUIDRA_TEST_PASS:' + step['marker'], flush=True)
        return 0


if __name__ == '__main__':
    sys.exit(main())
