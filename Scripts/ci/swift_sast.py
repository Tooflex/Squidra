#!/usr/bin/env python3
"""Local Swift AST checks with exact file coverage and content-free diagnostics."""
from datetime import datetime, timezone
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]
VERSION='1.180.0'
RULES=ROOT/'Scripts/ci/swift-rules.json'

def validate(report, expected, code):
    if code not in (0,1) or report.get('errors'):raise ValueError('Analysis failed')
    scanned=report['paths']['scanned']
    if not expected or len(scanned)!=len(set(scanned)) or set(scanned)!=set(expected):raise ValueError('Incomplete coverage')
    findings=[]
    rules={rule['id'] for rule in json.loads(RULES.read_text())['rules']}
    for result in report['results']:
        if result['path'] not in expected or result['check_id'] not in rules or result.get('extra',{}).get('is_ignored'):raise ValueError('Invalid finding')
        line=result['start']['line']
        if type(line) is not int or line<1:raise ValueError('Invalid location')
        findings.append({'rule':result['check_id'],'path':result['path'],'line':line})
    if bool(findings)!=(code==1):raise ValueError('Exit status mismatch')
    return {'status':'findings' if findings else 'passed','files_scanned':len(scanned),'rules':sorted(rules),'findings':findings}

def scan(files):
    executable=shutil.which('semgrep')
    if not executable:raise ValueError('Missing analyzer')
    with tempfile.TemporaryDirectory(prefix='squidra-swift-sast-') as temporary:
        directory=Path(temporary)
        env={'PATH':os.environ['PATH'],'HOME':temporary,'XDG_CONFIG_HOME':temporary,'SEMGREP_SEND_METRICS':'off','SEMGREP_ENABLE_VERSION_CHECK':'0'}
        if Path('/etc/ssl/cert.pem').is_file():env['SSL_CERT_FILE']='/etc/ssl/cert.pem'
        version=subprocess.run([executable,'--version'],env=env,capture_output=True,timeout=30,check=True).stdout.decode().strip()
        if version!=VERSION:raise ValueError('Unqualified analyzer version')
        for name,data in files.items():
            path=Path(name)
            if path.is_absolute() or '..' in path.parts or not name.startswith('Sources/') or path.suffix!='.swift':raise ValueError('Invalid source path')
            target=directory/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
        # Semgrep can recover malformed Swift without reporting a parser error.
        # Require the pinned compiler to parse the exact same source snapshots.
        swift=shutil.which('swiftc')
        if not swift:raise ValueError('Missing Swift parser')
        compiler=subprocess.run([swift,'--version'],env=env,capture_output=True,timeout=30,check=True).stdout.decode()
        if not re.search(r'Swift version 6\.4\.2(?:\s|$)',compiler):raise ValueError('Unqualified Swift parser')
        parsed=subprocess.run([swift,'-frontend','-parse',*sorted(files)],cwd=directory,env=env,capture_output=True,timeout=90)
        if parsed.returncode:raise ValueError('Invalid Swift syntax')
        (directory/'rules.json').write_bytes(RULES.read_bytes())
        result=subprocess.run([executable,'scan','--config','rules.json','--metrics','off','--disable-version-check','--disable-nosem','--no-git-ignore','--no-rewrite-rule-ids','--strict','--error','--json','Sources'],cwd=directory,env=env,capture_output=True,timeout=180)
        summary=validate(json.loads(result.stdout),files,result.returncode)
        summary.update(analyzer='Semgrep CE '+VERSION,syntax_parser='Swift 6.4.2',rules_sha256=hashlib.sha256(RULES.read_bytes()).hexdigest(),checked_at_utc=datetime.now(timezone.utc).isoformat(),source_sha256={name:hashlib.sha256(data).hexdigest() for name,data in sorted(files.items())})
        return summary

def main():
    output=ROOT/'.build/security';output.mkdir(parents=True,exist_ok=True)
    try:
        names=subprocess.check_output(['git','ls-files','-z','Sources'],cwd=ROOT).decode().split('\0')
        files={}
        for name in names:
            if not name.endswith('.swift'):continue
            path=ROOT/name
            if path.is_symlink():raise ValueError('Linked source')
            files[name]=path.read_bytes()
        report=scan(files);code=0 if report['status']=='passed' else 1
    except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError):
        report={'status':'failed','reason':'Swift analysis incomplete','checked_at_utc':datetime.now(timezone.utc).isoformat()};code=2
    (output/'swift-sast.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({key:value for key,value in report.items() if key!='source_sha256'}))
    if code==0:print('SQUIDRA_TEST_PASS:swift_sast')
    return code

if __name__=='__main__':raise SystemExit(main())
