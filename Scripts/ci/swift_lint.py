#!/usr/bin/env python3
"""Pinned SwiftLint correctness/idiom rules with exact snapshot coverage."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]
CONFIG=ROOT/'Scripts/ci/swiftlint.yml'
RULES={'duplicate_imports','redundant_nil_coalescing','unused_control_flow_label','unused_optional_binding'}

def validate(findings, log, files, directory, code):
    if code not in (0,2) or not isinstance(findings,list) or not files:raise ValueError('Lint failed')
    final=re.findall(r'Done linting! Found (\d+) violations?, (\d+) serious in (\d+) files?\.',log)
    if len(final)!=1 or tuple(map(int,final[0]))!=(len(findings),len(findings),len(files)):raise ValueError('Incomplete lint coverage')
    progress=re.findall(r"Linting '.+' \((\d+)/(\d+)\)",log)
    if len(progress)!=len(files) or {int(a) for a,b in progress}!=set(range(1,len(files)+1)) or any(int(b)!=len(files) for a,b in progress):raise ValueError('Missing file results')
    if bool(findings)!=(code==2):raise ValueError('Lint exit mismatch')
    safe=[]
    for finding in findings:
        path=Path(finding['file']).relative_to(directory).as_posix()
        if path not in files or finding['rule_id'] not in RULES or type(finding['line']) is not int or finding['line']<1:raise ValueError('Unknown lint result')
        safe.append({'rule':finding['rule_id'],'path':path,'line':finding['line']})
    return {'status':'findings' if safe else 'passed','files_scanned':len(files),'rules':sorted(RULES),'findings':safe}

def scan(files):
    executable=shutil.which('swiftlint')
    if not executable:raise ValueError('Missing lint tool')
    with tempfile.TemporaryDirectory(prefix='squidra-lint-') as temporary:
        directory=Path(temporary);env={'PATH':os.environ['PATH'],'HOME':temporary}
        version=subprocess.run([executable,'version'],env=env,capture_output=True,check=True,timeout=30).stdout.decode().strip()
        if version!='0.65.1':raise ValueError('Unqualified SwiftLint version')
        for name,data in files.items():
            path=Path(name)
            if path.is_absolute() or '..' in path.parts or not name.startswith('Sources/') or path.suffix!='.swift':raise ValueError('Invalid source path')
            if re.search(rb'swiftlint\s*:\s*(?:disable|enable)',data):raise ValueError('Inline lint suppression is not permitted')
            target=directory/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
        config=CONFIG.read_bytes();(directory/'lint.yml').write_bytes(config)
        result=subprocess.run([executable,'lint','--config','lint.yml','--strict','--no-cache','--disable-sourcekit','--reporter','json','Sources'],cwd=directory,env=env,capture_output=True,timeout=120)
        report=validate(json.loads(result.stdout),result.stderr.decode(),files,directory,result.returncode)
        report.update(analyzer='SwiftLint 0.65.1',checked_at_utc=datetime.now(timezone.utc).isoformat(),config_sha256=hashlib.sha256(config).hexdigest())
        return report

def main():
    output=ROOT/'.build/security';output.mkdir(parents=True,exist_ok=True)
    try:
        names=subprocess.check_output(['git','ls-files','-z','Sources'],cwd=ROOT).decode().split('\0');files={}
        for name in names:
            if not name.endswith('.swift'):continue
            path=ROOT/name
            if path.is_symlink():raise ValueError('Linked source')
            files[name]=path.read_bytes()
        report=scan(files);code=0 if report['status']=='passed' else 1
    except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError):
        report={'status':'failed','reason':'Swift lint incomplete'};code=2
    (output/'swift-lint.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
    if code==0:print('SQUIDRA_TEST_PASS:swift_lint')
    return code

if __name__=='__main__':raise SystemExit(main())
