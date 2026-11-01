#!/usr/bin/env python3
"""Offline Gitleaks scan of tracked snapshots; never print matches or secrets."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import uuid

ROOT=Path(__file__).resolve().parents[2]
IMAGE='ghcr.io/gitleaks/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f'
CONFIG=ROOT/'Scripts/ci/gitleaks.toml'

def validate(findings, expected, code):
    if code not in (0,1) or not isinstance(findings,list) or not expected:raise ValueError('Incomplete secret scan')
    if bool(findings)!=(code==1):raise ValueError('Scanner status mismatch')
    safe=[]
    for finding in findings:
        path=finding['File'].removeprefix('/scan/')
        rule=finding['RuleID'];line=finding['StartLine']
        if path not in expected or not re.fullmatch('[A-Za-z0-9_.-]+',rule) or type(line) is not int or line<1:raise ValueError('Invalid scanner result')
        safe.append({'rule':rule,'path':path,'line':line})
    return {'status':'findings' if safe else 'passed','files_supplied':len(expected),'findings':safe}

def review(summary, files, exceptions):
    remaining=[];reviewed=[]
    for finding in summary['findings']:
        digest=hashlib.sha256(files[finding['path']]).hexdigest()
        matches=[item for item in exceptions if all(item[key]==finding[key] for key in ['path','rule','line']) and item['file_sha256']==digest]
        if len(matches)>1:raise ValueError('Duplicate reviewed exception')
        if matches:
            if not matches[0]['reason']:raise ValueError('Missing review reason')
            reviewed.append(finding)
        else:remaining.append(finding)
    summary.update(findings=remaining,reviewed_false_positives=reviewed,status='findings' if remaining else 'passed')
    return summary

def scan(files):
    if not files or len(files)>10000:raise ValueError('Invalid source inventory')
    if sum(map(len,files.values()))>268435456:raise ValueError('Snapshot too large')
    scratch=ROOT/'.build/security';scratch.mkdir(parents=True,exist_ok=True)
    nonce=uuid.uuid4().hex;identity=None
    def docker(*args):return subprocess.run(['docker',*args],check=True,capture_output=True,timeout=120)
    with tempfile.TemporaryDirectory(prefix='secret-',dir=scratch) as temporary:
        temp=Path(temporary);source=temp/'source';output=temp/'output';settings=temp/'settings'
        source.mkdir();output.mkdir();settings.mkdir()
        for name,data in files.items():
            path=Path(name)
            if path.is_absolute() or '..' in path.parts or name!=path.as_posix() or len(data)>16777216:raise ValueError('Unsupported tracked file')
            target=source/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
        (settings/'gitleaks.toml').write_bytes(CONFIG.read_bytes());(settings/'.gitleaksignore').write_text('')
        try:
            identity=docker('create','--label','io.squidra.secret-scan='+nonce,'--network','none','--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--cpus','1','--memory','512m','--mount','type=bind,source='+str(source)+',target=/scan,readonly','--mount','type=bind,source='+str(output)+',target=/output','--mount','type=bind,source='+str(settings)+',target=/settings,readonly',IMAGE,'dir','/scan','--config','/settings/gitleaks.toml','--gitleaks-ignore-path','/settings/.gitleaksignore','--ignore-gitleaks-allow','--redact=100','--no-banner','--log-level','error','--report-format','json','--report-path','/output/report.json','--exit-code','1','--timeout','90').stdout.decode().strip()
            result=subprocess.run(['docker','start','--attach',identity],capture_output=True,timeout=120)
            state=json.loads(docker('inspect',identity).stdout)[0]['State']
            if state['Running'] or state['ExitCode']!=result.returncode:raise ValueError('Scanner execution incomplete')
            report=output/'report.json'
            if not report.is_file() or report.stat().st_size>16777216:raise ValueError('Missing or excessive report')
            summary=validate(json.loads(report.read_bytes()),files,result.returncode)
            summary=review(summary,files,json.loads((ROOT/'Scripts/ci/secret-false-positives.json').read_text()))
            hashes={name:hashlib.sha256(data).hexdigest() for name,data in sorted(files.items())}
            summary.update(scanner_image=IMAGE,checked_at_utc=datetime.now(timezone.utc).isoformat(),snapshot_sha256=hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest(),bytes_supplied=sum(map(len,files.values())))
        finally:
            if identity:
                info=json.loads(docker('inspect',identity).stdout)[0]
                if info['Config']['Labels'].get('io.squidra.secret-scan')!=nonce:raise ValueError('Container ownership mismatch')
                docker('rm','-f',identity)
                if docker('ps','--all','--filter','id='+identity,'--format','{{.ID}}').stdout.strip():raise ValueError('Scanner cleanup incomplete')
    return summary

def main():
    output=ROOT/'.build/security';output.mkdir(parents=True,exist_ok=True)
    try:
        names=subprocess.check_output(['git','ls-files','-z'],cwd=ROOT).decode().split('\0')
        files={}
        for name in filter(None,names):
            path=ROOT/name
            if path.is_symlink() or not path.is_file():raise ValueError('Unsupported tracked object')
            files[name]=path.read_bytes()
        report=scan(files);code=0 if report['status']=='passed' else 1
    except (OSError,ValueError,KeyError,TypeError,AttributeError,subprocess.SubprocessError):
        report={'status':'failed','reason':'secret analysis incomplete','checked_at_utc':datetime.now(timezone.utc).isoformat()};code=2
    (output/'secrets.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
    if code==0:print('SQUIDRA_TEST_PASS:tracked_secret_scan')
    return code

if __name__=='__main__':raise SystemExit(main())
