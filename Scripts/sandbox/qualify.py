#!/usr/bin/env python3
"""Actual Linux engine qualification. Trusted probes only; not a user task API."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
PROFILE_SHA256 = 'e53c15d248f57bceec0a3a16fad1b4ab0d05a7bddb455f86a60e2dba5612cdf7'
TAG = 'localhost/squidra-browser:149.0.7827.53-r0'
IMAGE = None


def docker(*args, timeout=30, check=True):
    result = subprocess.run(['docker', *args], cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        # Commands can include public fixture paths/HTML; do not echo arbitrary daemon diagnostics.
        raise RuntimeError('Docker operation failed: ' + args[0])
    return result


class OwnedContainers:
    def __init__(self):
        self.nonce = uuid.uuid4().hex
        self.ids = set()

    def create(self, entrypoint, args):
        name = 'squidra-sandbox-' + uuid.uuid4().hex
        options = ['create', '--pull', 'never', '--name', name, '--label', 'io.squidra.sandbox.owner=' + self.nonce,
                   '--network', 'none', '--read-only', '--cap-drop', 'ALL',
                   '--security-opt', 'no-new-privileges', '--security-opt', 'seccomp=' + str(HERE / 'seccomp.json'),
                   '--user', '1000:1000', '--pids-limit', '128', '--memory', '512m', '--memory-swap', '512m',
                   '--cpus', '1', '--shm-size', '64m', '--ulimit', 'nofile=1024:1024',
                   '--tmpfs', '/work:rw,nosuid,nodev,size=32m,uid=1000,gid=1000,mode=700',
                   '--tmpfs', '/tmp:rw,nosuid,nodev,size=64m,mode=1777',
                   '--entrypoint', entrypoint, IMAGE, *args]
        try:
            container = docker(*options).stdout.strip()
            if not re.fullmatch('[0-9a-f]{64}', container):
                raise RuntimeError('Invalid immutable container identity')
        except BaseException:
            # Lost create acknowledgement: discover ONLY the exact generated name,
            # then verify its nonce before adding it to this invocation's cleanup set.
            found = docker('inspect', name, check=False)
            if found.returncode == 0:
                record = json.loads(found.stdout)[0]
                if record['Config']['Labels'].get('io.squidra.sandbox.owner') == self.nonce:
                    self.ids.add(record['Id'])
            raise
        self.ids.add(container)
        return container

    def inspect(self, container):
        return json.loads(docker('inspect', container).stdout)[0]

    def destroy(self, container):
        if container not in self.ids:
            raise ValueError('Container is not owned by this invocation')
        found = docker('inspect', container, check=False)
        if found.returncode:
            # A daemon failure is not evidence that a resource was cleaned up.
            raise RuntimeError('Cannot verify owned container before destruction')
        record = json.loads(found.stdout)[0]
        if record['Id'] != container or record['Config']['Labels'].get('io.squidra.sandbox.owner') != self.nonce:
            raise ValueError('Container ownership mismatch')
        docker('rm', '-f', container)
        self.ids.remove(container)

    def run(self, entrypoint, args, expected=0):
        container = self.create(entrypoint, args)
        try:
            result = docker('start', '--attach', container, check=False)
            record = self.inspect(container)
            if record['State']['Running'] or record['State']['ExitCode'] != expected:
                raise RuntimeError('Probe exit did not match expected outcome')
            return result.stdout
        finally:
            self.destroy(container)

    def close(self):
        errors = []
        for container in list(self.ids):
            try:
                self.destroy(container)
            except Exception as error:
                errors.append(type(error).__name__)
        if errors:
            raise RuntimeError('Owned sandbox cleanup failed')


def main():
    global IMAGE
    output = ROOT / '.build/sandbox'
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / 'qualification.json'
    report_path.unlink(missing_ok=True)
    if hashlib.sha256((HERE / 'seccomp.json').read_bytes()).hexdigest() != PROFILE_SHA256:
        raise RuntimeError('Unreviewed seccomp profile')
    server = json.loads(docker('version', '--format', '{{json .Server}}').stdout)
    if server['Os'] != 'linux':
        raise RuntimeError('Only a Linux container engine is supported')
    with (output / 'build.log').open('w') as log:
        subprocess.run(['docker', 'build', '--tag', TAG, str(HERE)], cwd=ROOT,
                       stdout=log, stderr=log, check=True, timeout=300)
    IMAGE = docker('image', 'inspect', '--format', '{{.Id}}', TAG).stdout.strip()
    if not re.fullmatch('sha256:[0-9a-f]{64}', IMAGE):
        raise RuntimeError('Image was not resolved to immutable ID')
    owner = OwnedContainers()
    passed = []

    def mark(name):
        passed.append(name)
        print('SQUIDRA_TEST_PASS:' + name, flush=True)

    try:
        version = owner.run('/usr/bin/chromium-browser', ['--version']).strip()
        if not version.startswith('Chromium 149.0.7827.53'):
            raise RuntimeError('Unexpected browser version')
        kernel = owner.run('/bin/uname', ['-sr']).strip()
        packages = sorted(owner.run('/sbin/apk', ['info', '-v']).splitlines())
        mark('linux_browser_version')

        browser = ['--headless', '--disable-gpu', '--disable-setuid-sandbox', '--user-data-dir=/work/profile',
                   '--no-first-run', '--disable-background-networking', '--dump-dom']
        status = owner.run('/usr/bin/chromium-browser', browser + ['--allow-chrome-scheme-url', 'chrome://sandbox'])
        for label, value in [('Layer 1 Sandbox', 'Namespace'), ('PID namespaces', 'Yes'),
                             ('Network namespaces', 'Yes'), ('Seccomp-BPF sandbox', 'Yes')]:
            if f'>{label}</td><td class="good">{value}</td>' not in status:
                raise RuntimeError('Internal Chromium sandbox is not verified')
        mark('chromium_internal_sandbox')

        rendered = owner.run('/usr/bin/chromium-browser', browser + [
            'data:text/html,<p id="result">before</p><script>document.getElementById("result").textContent="SQUIDRA_RENDERED"</script>'])
        if '<p id="result">SQUIDRA_RENDERED</p>' not in rendered:
            raise RuntimeError('Browser did not execute the authored rendering fixture')
        mark('browser_render')

        container = owner.create('/bin/sleep', ['30'])
        settings = owner.inspect(container)['HostConfig']
        if (settings['NetworkMode'] != 'none' or settings['Privileged'] or settings['Binds']
                or settings['Devices'] or not settings['ReadonlyRootfs'] or settings['CapDrop'] != ['ALL']
                or settings['Memory'] != 536870912 or settings['MemorySwap'] != 536870912
                or settings['PidsLimit'] != 128 or settings['NanoCpus'] != 1000000000
                or settings['IpcMode'] == 'host' or settings['PidMode'] == 'host'):
            raise RuntimeError('Unexpected container boundary')
        owner.destroy(container)
        limits = owner.run('/bin/sh', ['-c',
            'cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max /sys/fs/cgroup/pids.max /sys/fs/cgroup/cpu.max; '
            'id -u; grep -E "^(CapEff|NoNewPrivs|Seccomp):" /proc/self/status'])
        for value in ['536870912\n', '0\n', '128\n', '100000 100000\n', '1000\n',
                      'CapEff:\t0000000000000000', 'NoNewPrivs:\t1', 'Seccomp:\t2']:
            if value not in limits:
                raise RuntimeError('Kernel resource or privilege limits are absent')
        mark('kernel_limits')

        sentinel = output / ('host-sentinel-' + uuid.uuid4().hex)
        sentinel.write_text('PUBLIC_HOST_SENTINEL')
        try:
            owner.run('/bin/sh', ['-c',
                'test ! -e "$1" && test ! -e /proc/1/root"$1" && test ! -S /var/run/docker.sock '
                '&& ! touch /etc/squidra-escape && ! mount -t tmpfs tmpfs /mnt', 'probe', str(sentinel)])
        finally:
            sentinel.unlink(missing_ok=True)
        mark('host_access_denied')

        owner.run('/bin/sh', ['-c',
            '! wget -T 2 -q -O /dev/null http://1.1.1.1 && '
            '! wget -T 2 -q -O /dev/null http://169.254.169.254 && '
            'test "$(ls /sys/class/net)" = lo'])
        mark('network_denied')

        owner.run('/bin/sh', ['-c',
            'dd if=/dev/zero of=/work/too-large bs=1048576 count=33 2>/tmp/quota-error; '
            'test $? -ne 0 && grep -q "No space left on device" /tmp/quota-error'])
        owner.run('/bin/sh', ['-c', 'test ! -e /work/too-large && test ! -e /tmp/quota-error'])
        mark('workspace_quota_and_isolation')

        held = owner.create('/bin/sleep', ['30'])
        stranger = OwnedContainers()
        try:
            stranger.destroy(held)
            raise RuntimeError('Foreign container destruction was accepted')
        except ValueError:
            pass
        if owner.inspect(held)['Id'] != held:
            raise RuntimeError('Foreign cleanup altered the owned resource')
        owner.destroy(held)
        if docker('inspect', held, check=False).returncode == 0:
            raise RuntimeError('Owned resource survived cleanup')
        mark('owned_cleanup')

        report = {'schemaVersion': 1, 'observedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  'engine': {'name': 'Docker', 'version': server['Version'], 'os': server['Os'], 'arch': server['Arch']},
                  'imageID': IMAGE, 'browserVersion': version, 'kernel': kernel,
                  'packages': packages, 'seccompSHA256': PROFILE_SHA256,
                  'checks': passed, 'outcome': 'passed',
                  'scope': 'Linux container engine confinement; Swift adapter, user-task cancellation and native OS support not yet qualified'}
    finally:
        owner.close()
    report_path.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
