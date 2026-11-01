#!/usr/bin/env python3
"""Actual Linux ownership tests, exact production/test files in a focused package."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid

root=Path(__file__).resolve().parents[2]
base=root/'.build/linux-qualification';base.mkdir(exist_ok=True)
image='localhost/squidra-swift-linux-qualification:6.4.2-noble'
name='squidra-linux-ownership-'+uuid.uuid4().hex[:12]
nonce=uuid.uuid4().hex
identity=None

def docker(*args,**kwargs):return subprocess.run(['docker',*args],check=True,capture_output=True,timeout=300,**kwargs)

with tempfile.TemporaryDirectory(prefix='ownership-',dir=base) as temporary:
    target=Path(temporary)
    sources={
        'Sources/CSquidraPlatform/include/CSquidraPlatform.h':'Sources/CSquidraPlatform/include/CSquidraPlatform.h',
        'Sources/CSquidraPlatform/filesystem.c':'Sources/CSquidraPlatform/filesystem.c',
        'Sources/SquidraAgentRuntime/Recovery/LocalRunOwnership.swift':'Sources/SquidraAgentRuntime/LocalRunOwnership.swift',
        'Tests/SquidraAgentRuntimeTests/LocalRunOwnershipTests.swift':'Tests/SquidraAgentRuntimeTests/LocalRunOwnershipTests.swift',
    }
    hashes={}
    for source,destination in sources.items():
        path=target/destination;path.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(root/source,path)
        hashes[source]=hashlib.sha256(path.read_bytes()).hexdigest()
    (target/'Package.swift').write_text('// swift-tools-version: 6.4\nimport PackageDescription\nlet package=Package(name:"OwnershipQualification",targets:[.target(name:"CSquidraPlatform"),.target(name:"SquidraAgentRuntime",dependencies:["CSquidraPlatform"]),.testTarget(name:"SquidraAgentRuntimeTests",dependencies:["CSquidraPlatform","SquidraAgentRuntime"])])\n')
    try:
        build=docker('build','-f',str(root/'Tests/InstallTests/linux-swift.Dockerfile'),'-t',image,str(root/'Tests/InstallTests'))
        (base/'image-build.log').write_bytes(build.stdout+build.stderr)
        image_id=docker('image','inspect','--format','{{.Id}}',image).stdout.decode().strip()
        identity=docker('create','--name',name,'--label','io.squidra.linux-ownership='+nonce,'--network','none','--cpus','2','--memory','2g','--mount','type=bind,source='+str(target)+',target=/src','--workdir','/src',image_id,'bash','-lc','swift --version && python3 --version && swift test --disable-swift-testing -j 2 --filter LocalRunOwnershipTests').stdout.decode().strip()
        execution=subprocess.run(['docker','start','--attach',identity],capture_output=True,timeout=180)
        output=execution.stdout+execution.stderr
        (base/'ownership-test.log').write_bytes(output)
        info=json.loads(docker('inspect',identity).stdout)[0]
        if execution.returncode or info['State']['Running'] or info['State']['ExitCode']!=0:
            print(output.decode(errors='replace'));raise RuntimeError('Linux ownership tests failed')
        # Linux XCTest does not emit Swift Testing's xUnit file. Require each
        # exact selected XCTest and the successful zero-failure suite summary.
        log=output.decode(errors='replace')
        expected=set(re.findall(r'func (test\w+)\(', (target/'Tests/SquidraAgentRuntimeTests/LocalRunOwnershipTests.swift').read_text()))
        passed=re.findall(r"Test Case 'LocalRunOwnershipTests\.(test\w+)' passed ",log)
        if len(expected)!=5 or len(passed)!=5 or set(passed)!=expected or 'Executed 5 tests, with 0 failures (0 unexpected)' not in log or re.search(r"Test Case .* (failed|skipped) ",log):
            raise RuntimeError('Incomplete Linux ownership result')
        (base/'ownership-report.json').write_text(json.dumps({'scope':'exact ownership sources and tests; focused Swift package, not full application test suite','image_id':image_id,'source_hashes':hashes,'tests':5,'passed':5,'failed':0,'skipped':0},indent=2)+'\n')
    finally:
        if identity:
            info=json.loads(docker('inspect',identity).stdout)[0]
            if info['Config']['Labels'].get('io.squidra.linux-ownership')!=nonce:raise RuntimeError('Ownership mismatch')
            docker('rm','-f',identity)
            if docker('ps','--all','--filter','id='+identity,'--format','{{.ID}}').stdout.strip():raise RuntimeError('Container cleanup failed')
print('SQUIDRA_TEST_PASS:linux_ownership')
