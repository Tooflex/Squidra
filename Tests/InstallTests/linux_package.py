#!/usr/bin/env python3
"""Build clean tracked sources; install on Ubuntu ARM64 without a Swift toolchain."""
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import time
import uuid

root=Path(__file__).resolve().parents[2]
base=root/'.build/linux-package';base.mkdir(parents=True,exist_ok=True)
nonce=uuid.uuid4().hex
owned=[]

def run(args,**kwargs):
    return subprocess.run(args,check=True,capture_output=True,timeout=900,**kwargs)
def docker(*args):return run(['docker',*args])
def create(*args):
    identity=docker('create','--label','io.squidra.linux-package='+nonce,*args).stdout.decode().strip()
    owned.append(identity)
    return identity
def execute(identity,log):
    result=subprocess.run(['docker','start','--attach',identity],capture_output=True,timeout=900)
    output=result.stdout+result.stderr
    (base/log).write_bytes(output)
    state=json.loads(docker('inspect',identity).stdout)[0]['State']
    if result.returncode or state['Running'] or state['ExitCode']:
        print(output.decode(errors='replace'));raise RuntimeError('Linux package stage failed')
    return result.stdout

# A source commit is a verifiable package identity; never label a dirty snapshot clean.
if run(['git','status','--porcelain'],cwd=root).stdout.strip():raise SystemExit('Commit the candidate before Linux package qualification')
commit=run(['git','rev-parse','HEAD'],cwd=root).stdout.decode().strip()
cache=base/'build-cache';cache.mkdir(exist_ok=True)
try:
    with tempfile.TemporaryDirectory(prefix='candidate-',dir=base) as temporary:
        temp=Path(temporary);source=temp/'source'
        run(['git','clone','--no-hardlinks','--no-local',str(root),str(source)])
        run(['git','checkout','--detach',commit],cwd=source)
        image_ids={}
        for stage in ['builder','runtime']:
            tag='localhost/squidra-linux-package:'+stage
            result=docker('build','--target',stage,'-f',str(root/'Tests/InstallTests/linux-package.Dockerfile'),'-t',tag,str(root/'Tests/InstallTests'))
            (base/(stage+'-image.log')).write_bytes(result.stdout+result.stderr)
            image_ids[stage]=docker('image','inspect','--format','{{.Id}}',tag).stdout.decode().strip()
        build=create('--cpus','4','--memory','6g','--mount','type=bind,source='+str(source)+',target=/src','--mount','type=bind,source='+str(cache)+',target=/src/.build','--workdir','/src',image_ids['builder'],'bash','-lc','git config --global --add safe.directory /src && cd web && npm ci --ignore-scripts && cd .. && python3 packaging/build.py')
        output=execute(build,'build.log')
        built=json.loads(output.decode().splitlines()[-1])
        archive=cache/'packaging'/Path(built['archive']).name
        artifacts=base/'artifacts';artifacts.mkdir(exist_ok=True)
        shutil.copy2(archive,artifacts/archive.name)
        shutil.copy2(archive.with_suffix('.sha256'),artifacts/archive.with_suffix('.sha256').name)
        report=artifacts/'build-report.json';report.write_text(json.dumps(built))
        # Runtime sees only the package and installer/test support, never source or build cache.
        support=temp/'support'
        for relative in ['Scripts/install/package.py','Tests/InstallTests/qualify.py']:
            destination=support/relative;destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(root/relative,destination)
        password=secrets.token_urlsafe(32)
        envfile=temp/'postgres.env';envfile.touch(mode=0o600)
        envfile.write_text('POSTGRES_DB=squidra\nPOSTGRES_USER=squidra\nPOSTGRES_PASSWORD='+password+'\n')
        connection=temp/'database.json';connection.touch(mode=0o600)
        connection.write_text(json.dumps({'port':5432,'password':password}))
        db_name='squidra-linux-package-db-'+nonce[:12]
        db=create('--name',db_name,'--label','io.squidra.database=test','--network','none','--env-file',str(envfile),'--tmpfs','/var/lib/postgresql/data:rw,nosuid,size=1g','localhost/squidra-postgres:17-postgis3.6.4-vector0.8.7')
        docker('start',db)
        for _ in range(60):
            if subprocess.run(['docker','exec',db,'pg_isready','-U','squidra','-d','squidra'],capture_output=True).returncode==0:break
            time.sleep(.25)
        else:raise RuntimeError('Test database did not become ready')
        run(['bash','Scripts/dev-db.sh','migrate'],cwd=root,env=dict(os.environ,SQUIDRA_DB_CONTAINER=db_name,SQUIDRA_CONTAINER_ENGINE='docker'))
        runtime=create('--network','container:'+db,'--cpus','2','--memory','2g','--mount','type=bind,source='+str(support)+',target=/support,readonly','--mount','type=bind,source='+str(artifacts)+',target=/package,readonly','--mount','type=bind,source='+str(connection)+',target=/database.json,readonly','--env','SQUIDRA_INSTALL_ARCHIVE=/package/'+archive.name,'--env','SQUIDRA_INSTALL_BUILD_REPORT=/package/build-report.json','--env','SQUIDRA_INSTALL_DATABASE_FILE=/database.json',image_ids['runtime'],'python3','/support/Tests/InstallTests/qualify.py')
        output=execute(runtime,'runtime.log')
        expected={'verified_install','native_cli','installed_server_database','installed_web','safe_uninstall','unsafe_archives_rejected'}
        markers=[line.removeprefix('SQUIDRA_TEST_PASS:') for line in output.decode().splitlines() if line.startswith('SQUIDRA_TEST_PASS:')]
        if len(markers)!=6 or set(markers)!=expected:raise RuntimeError('Incomplete package qualification')
        (base/'qualification.json').write_text(json.dumps({'source_commit':commit,'archive_sha256':built['sha256'],'images':image_ids,'checks':markers,'target':'Ubuntu 24.04 ARM64; container kernel','swift_toolchain_in_runtime':False},indent=2)+'\n')
        print(output.decode())
finally:
    for identity in reversed(owned):
        info=json.loads(docker('inspect',identity).stdout)[0]
        if info['Config']['Labels'].get('io.squidra.linux-package')!=nonce:raise RuntimeError('Container ownership mismatch')
        docker('rm','-f',identity)
        if docker('ps','--all','--filter','id='+identity,'--format','{{.ID}}').stdout.strip():raise RuntimeError('Container cleanup failed')
print('SQUIDRA_TEST_PASS:owned_cleanup')
