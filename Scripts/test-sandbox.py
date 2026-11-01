#!/usr/bin/env python3
"""Strict offline/real-engine/Swift-adapter qualification. No paid providers."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent


def suite(name, marker, env=None):
    report = ROOT / '.build/issue-tests' / name / 'summary.json'
    report.unlink(missing_ok=True)
    result = subprocess.run(['bash', 'Scripts/test-issue.sh', name], cwd=ROOT, env=env,
                            capture_output=True, text=True)
    for line in result.stdout.splitlines():
        if not line.startswith('SQUIDRA_TEST_PASS:'):
            print(line, flush=True)
    print(result.stderr, file=sys.stderr, end='')
    if result.returncode:
        sys.exit(result.returncode)
    summary = json.loads(report.read_text())
    count = summary['selected']
    if (type(count) is not int or count <= 0 or summary['status'] != 'passed' or summary['passed'] != count
            or any(summary[k] != 0 for k in ['failed', 'skipped', 'not_executed'])):
        sys.exit('Incomplete sandbox suite')
    print('SQUIDRA_TEST_PASS:' + marker, flush=True)


def main():
    output = ROOT / '.build/sandbox/adapter-qualification.json'
    output.unlink(missing_ok=True)
    suite('SQD-012-UNIT', 'sandbox_contracts')
    suite('SQD-012-ENGINE', 'linux_engine')
    engine = json.loads((ROOT / '.build/sandbox/qualification.json').read_text())
    if engine['outcome'] != 'passed' or engine['engine']['os'] != 'linux' or engine['engine']['arch'] != 'arm64':
        sys.exit('Unsupported engine qualification')
    if os.environ.get('DOCKER_HOST') and not os.environ.get('DOCKER_CONTEXT'):
        host = os.environ['DOCKER_HOST']
    else:
        args = ['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}']
        if os.environ.get('DOCKER_CONTEXT'):
            args.append(os.environ['DOCKER_CONTEXT'])
        host = subprocess.check_output(args, text=True, timeout=10).strip()
    if not host.startswith('unix:///') or not Path(host[7:]).is_socket():
        sys.exit('A local verified Docker Unix socket is required')
    executable = shutil.which('docker')
    if not executable:
        sys.exit('Docker binary unavailable')
    env = {k: v for k, v in os.environ.items() if k not in ('MODEL_API_KEY', 'MODEL_API_KEY_FILE')}
    env.update(SQUIDRA_SANDBOX_LIVE='1', SQUIDRA_SANDBOX_IMAGE=engine['imageID'],
               SQUIDRA_SANDBOX_DOCKER=executable, SQUIDRA_SANDBOX_SOCKET=host[7:])
    suite('SQD-012-LIVE-SWIFT', 'swift_browser_adapter', env)
    output.write_text(json.dumps({'schemaVersion': 1, 'observedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                                 'engine': engine, 'swiftAdapter': 'passed', 'liveTests': 4,
                                 'scope': 'macOS Swift host with Linux arm64 Docker engine; offline rendering, limits and joined cancellation'}, indent=2) + '\n')


if __name__ == '__main__':
    main()
