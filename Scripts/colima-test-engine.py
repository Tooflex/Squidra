#!/usr/bin/env python3
"""Opt-in Docker wrapper for a broken default Colima SSH port forwarder.

Only forwards loopback ports of labeled Squidra test containers. Removes
owned forwards when the database runner removes each container.
"""
import os
from pathlib import Path
import re
import socket
import subprocess
import sys

STATE = Path(__file__).resolve().parent.parent / '.build/colima-forwards'
CONFIG = str(Path.home() / '.colima/_lima/colima/ssh.config')


def is_test_name(name):
    return re.fullmatch(r'squidra-client-test-[0-9a-f]{12}', name) is not None


def forward(action, port):
    return subprocess.run([
        'ssh', '-F', CONFIG, '-O', action,
        '-L', f'127.0.0.1:{port}:127.0.0.1:{port}', 'lima-colima',
    ], capture_output=True, timeout=10)


def main():
    args = sys.argv[1:]
    if len(args) == 3 and args[0] == 'port' and is_test_name(args[1]):
        result = subprocess.run(['docker', *args], capture_output=True, text=True)
        if result.returncode:
            sys.stderr.write(result.stderr)
            return result.returncode
        binding = result.stdout.strip()
        match = re.fullmatch(r'127\.0\.0\.1:([0-9]+)', binding)
        if not match or not 1 <= int(match[1]) <= 65535:
            sys.exit('Unexpected test database binding')
        port = int(match[1])
        label = subprocess.check_output([
            'docker', 'inspect', '--format',
            '{{index .Config.Labels "io.squidra.database"}}', args[1],
        ], text=True).strip()
        if label != 'test':
            sys.exit('Refusing to forward a non-test container')
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=1):
                pass
        except OSError:
            if forward('forward', port).returncode:
                sys.exit('Unable to forward test database with the default Colima SSH configuration')
            STATE.mkdir(parents=True, exist_ok=True)
            (STATE / args[1]).write_text(str(port))
        print(binding)
        return 0
    if args and args[0] == 'rm':
        for name in args[1:]:
            if is_test_name(name):
                record = STATE / name
                if record.exists():
                    # Always let Docker remove the owned test container even if SSH fails.
                    try:
                        if forward('cancel', int(record.read_text())).returncode:
                            print('Warning: test port forwarding cleanup failed', file=sys.stderr)
                        else:
                            record.unlink()
                    except (OSError, ValueError, subprocess.TimeoutExpired):
                        print('Warning: test port forwarding cleanup failed', file=sys.stderr)
    os.execvp('docker', ['docker', *args])


if __name__ == '__main__':
    sys.exit(main())
