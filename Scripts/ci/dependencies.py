#!/usr/bin/env python3
"""Fail-closed OSV analysis of the exact Swift and npm resolved inventories."""
import collections
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import uuid

IMAGE='ghcr.io/google/osv-scanner@sha256:5116601dedc01c1c580eb92371883ec052fc4c13c3fbc109d621a63ac416d475'
ROOT=Path(__file__).resolve().parents[2]


def inventory(swift, npm):
    expected={}
    pins=swift['pins']
    if swift['version']!=3 or not pins:raise ValueError('Invalid Swift lockfile')
    swift_packages=[]
    for pin in pins:
        location=pin['location'];state=pin['state']
        if pin['kind']!='remoteSourceControl' or not re.fullmatch(r'https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?',location) or not re.fullmatch('[0-9a-f]{40}',state['revision']) or not state.get('version'):raise ValueError('Unsupported Swift pin')
        swift_packages.append(('SwiftURL',location.removeprefix('https://').removesuffix('.git'),state['version']))
    expected['/locks/Package.resolved']=collections.Counter(swift_packages)
    if npm['lockfileVersion']!=3:raise ValueError('Unsupported npm lockfile')
    npm_packages=[]
    for path,entry in npm['packages'].items():
        if not path:continue
        if 'node_modules/' not in path or entry.get('link') or not entry.get('version'):raise ValueError('Unsupported npm pin')
        npm_packages.append(('npm',entry.get('name',path.rsplit('node_modules/',1)[1]),entry['version']))
    if not npm_packages:raise ValueError('Empty npm lockfile')
    expected['/locks/package-lock.json']=collections.Counter(npm_packages)
    return expected


def validate(report, expected, exit_code):
    if exit_code not in (0,1):raise ValueError('Scanner execution failed')
    actual={};advisories=set();affected=set()
    for result in report['results']:
        source=result['source'];path=source['path']
        if source['type']!='lockfile' or path not in expected or path in actual:raise ValueError('Unexpected scanner source')
        actual[path]=collections.Counter()
        for entry in result['packages']:
            package=entry['package']
            actual[path][(package['ecosystem'],package['name'],package['version'])]+=1
            for vulnerability in entry.get('vulnerabilities',[]):
                identifier=vulnerability['id']
                if not isinstance(identifier,str) or not identifier:raise ValueError('Invalid advisory')
                advisories.add(identifier)
                affected.add((package['ecosystem'],package['name'],package['version']))
    if actual!=expected:raise ValueError('Scanner coverage mismatch')
    if bool(advisories)!=(exit_code==1):raise ValueError('Scanner status mismatch')
    return {'status':'vulnerabilities' if advisories else 'passed','swift_packages':sum(expected['/locks/Package.resolved'].values()),'npm_packages':sum(expected['/locks/package-lock.json'].values()),'advisory_ids':sorted(advisories),'affected_packages':[dict(zip(['ecosystem','name','version'],p)) for p in sorted(affected)]}


def scan(swift_path, npm_path):
    swift_bytes=swift_path.read_bytes();npm_bytes=npm_path.read_bytes()
    expected=inventory(json.loads(swift_bytes),json.loads(npm_bytes))
    nonce=uuid.uuid4().hex;identity=None
    def docker(*args):return subprocess.run(['docker',*args],capture_output=True,check=True,timeout=120)
    scratch=ROOT/'.build/security';scratch.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='dependency-',dir=scratch) as temporary:
        directory=Path(temporary)
        (directory/'Package.resolved').write_bytes(swift_bytes);(directory/'package-lock.json').write_bytes(npm_bytes)
        try:
            identity=docker('create','--label','io.squidra.dependency-scan='+nonce,'--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--memory','512m','--cpus','1','--mount','type=bind,source='+str(directory)+',target=/locks,readonly',IMAGE,'scan','source','--format','json','--all-packages','--all-vulns','--lockfile','/locks/Package.resolved','--lockfile','/locks/package-lock.json').stdout.decode().strip()
            result=subprocess.run(['docker','start','--attach',identity],capture_output=True,timeout=120)
            state=json.loads(docker('inspect',identity).stdout)[0]['State']
            if state['Running'] or result.returncode!=state['ExitCode']:raise ValueError('Scanner execution incomplete')
            summary=validate(json.loads(result.stdout),expected,result.returncode)
            summary['scanner_image']=IMAGE
            summary['lock_sha256']={'Package.resolved':hashlib.sha256(swift_bytes).hexdigest(),'package-lock.json':hashlib.sha256(npm_bytes).hexdigest()}
            summary['checked_at_utc']=datetime.now(timezone.utc).isoformat()
        finally:
            if identity:
                info=json.loads(docker('inspect',identity).stdout)[0]
                if info['Config']['Labels'].get('io.squidra.dependency-scan')!=nonce:raise ValueError('Container ownership mismatch')
                docker('rm','-f',identity)
                if docker('ps','--all','--filter','id='+identity,'--format','{{.ID}}').stdout.strip():raise ValueError('Scanner cleanup incomplete')
    return summary


def main():
    try:
        report=scan(ROOT/'Package.resolved',ROOT/'web/package-lock.json')
        output=ROOT/'.build/security';output.mkdir(parents=True,exist_ok=True)
        (output/'dependencies.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report))
        if report['status']=='passed':print('SQUIDRA_TEST_PASS:resolved_dependency_scan')
        return 0 if report['status']=='passed' else 1
    except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError):
        output=ROOT/'.build/security';output.mkdir(parents=True,exist_ok=True)
        report={'status':'failed','reason':'dependency analysis incomplete','checked_at_utc':datetime.now(timezone.utc).isoformat()}
        (output/'dependencies.json').write_text(json.dumps(report)+'\n')
        print(json.dumps(report));return 2

if __name__=='__main__':raise SystemExit(main())
