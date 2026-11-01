#!/usr/bin/env python3
"""Real native package install, running service, Web assets, and safe uninstall."""
import hashlib
import http.client
import importlib.util
import io
import json
import os
from pathlib import Path
import secrets
import selectors
import signal
import socket
import stat
import subprocess
import tempfile
import time
import uuid
import zipfile

root=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('installer',root/'Scripts/install/package.py');pkg=importlib.util.module_from_spec(spec);spec.loader.exec_module(pkg)
prebuilt=os.environ.get('SQUIDRA_INSTALL_ARCHIVE')
external_db=os.environ.get('SQUIDRA_INSTALL_DATABASE_FILE')
if bool(prebuilt)!=bool(external_db): raise SystemExit('Prebuilt test requires its isolated database configuration')
if prebuilt:
    archive=Path(prebuilt)
    built=json.loads(Path(os.environ['SQUIDRA_INSTALL_BUILD_REPORT']).read_text())
else:
    result=subprocess.run(['python3','packaging/build.py'],cwd=root,capture_output=True,text=True,timeout=600)
    if result.returncode:
        print(result.stdout+result.stderr);raise SystemExit(result.returncode)
    built=json.loads(result.stdout.splitlines()[-1]);archive=Path(built['archive'])
engine=os.environ.get('SQUIDRA_CONTAINER_ENGINE','docker');identity=None
name='squidra-client-test-'+uuid.uuid4().hex[:12];nonce=uuid.uuid4().hex

def run(args,**kwargs): return subprocess.run(args,check=True,capture_output=True,timeout=120,**kwargs)
def wait_banner(process,prefix):
    selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ)
    until=time.monotonic()+20
    try:
        while time.monotonic()<until and process.poll() is None:
            if selector.select(.2):
                line=process.stdout.readline().strip()
                if line.startswith(prefix): return int(line.rsplit(':',1)[1])
        raise AssertionError('Installed service did not bind')
    finally: selector.close()
def get(port,path):
    c=http.client.HTTPConnection('127.0.0.1',port,timeout=8)
    try:
        c.request('GET',path);r=c.getresponse();return r.status,r.read()
    finally:c.close()
def stop(p):
    if p.poll() is None:p.send_signal(signal.SIGTERM)
    try:p.wait(timeout=15)
    except subprocess.TimeoutExpired:p.kill();p.wait();raise AssertionError('Installed service did not stop gracefully')
    if p.returncode!=0:raise AssertionError('Installed service exited unsuccessfully')

try:
    with tempfile.TemporaryDirectory(prefix='squidra-install-') as directory:
        temp=Path(directory);prefix=temp/'installed'
        try:pkg.install(archive,prefix,'0'*64);raise AssertionError('Bad hash accepted')
        except ValueError:pass
        assert not prefix.exists()
        pkg.install(archive,prefix,built['sha256'])
        receipt=json.loads((prefix/'manifest.json').read_text());assert receipt['files']['bin/squidra']['mode']==0o755
        try:pkg.install(archive,prefix,built['sha256']);raise AssertionError('Existing prefix replaced')
        except FileExistsError:pass
        print('SQUIDRA_TEST_PASS:verified_install')
        env={'PATH':os.environ['PATH'],'HOME':directory,'LANG':'C'}
        for arg in ['--help','--version']:
            output=run([str(prefix/'bin/squidra'),arg],cwd=directory,env=env).stdout
            assert b'Squidra' in output or b'squidra' in output
        if pkg.target()=='darwin-arm64':
            load_commands=run(['/usr/bin/otool','-l',str(prefix/'bin/squidra')]).stdout
            assert b'/Applications/Xcode' not in load_commands
            assert (prefix/'bin/libswiftCompatibilitySpan.dylib').is_file()
            run(['/usr/bin/codesign','--verify',str(prefix/'bin/squidra')])
        else:
            assert not __import__('shutil').which('swift'), 'Runtime qualification must not have a Swift toolchain'
            dependencies=run(['ldd',str(prefix/'bin/squidra')]).stdout
            assert b'not found' not in dependencies
        print('SQUIDRA_TEST_PASS:native_cli')
        if external_db:
            connection=json.loads(Path(external_db).read_text())
            port=connection['port'];password=connection['password']
        else:
            credentials=temp/'credentials';credentials.touch(mode=0o600);password=secrets.token_urlsafe(32)
            credentials.write_text('POSTGRES_DB=squidra\nPOSTGRES_USER=squidra\nPOSTGRES_PASSWORD='+password+'\n')
            identity=run([engine,'create','--name',name,'--label','io.squidra.database=test','--label','io.squidra.install-test='+nonce,'--publish','127.0.0.1::5432','--env-file',str(credentials),'--tmpfs','/var/lib/postgresql/data:rw,nosuid,size=1g','localhost/squidra-postgres:17-postgis3.6.4-vector0.8.7']).stdout.decode().strip()
            run([engine,'start',identity])
            for _ in range(60):
                if subprocess.run([engine,'exec',identity,'pg_isready','-U','squidra','-d','squidra'],capture_output=True).returncode==0:break
                time.sleep(.25)
            else:raise AssertionError('DB readiness timeout')
            binding=run([engine,'port',name,'5432/tcp']).stdout.decode().strip()
            assert binding.startswith('127.0.0.1:');port=int(binding.split(':')[1])
            with socket.create_connection(('127.0.0.1',port),timeout=5):pass
            run(['bash','Scripts/dev-db.sh','migrate'],cwd=root,env=dict(os.environ,SQUIDRA_DB_CONTAINER=name,SQUIDRA_CONTAINER_ENGINE=engine))
        service_env=dict(env,SQUIDRA_PROFILE='offline',SQUIDRA_AUTH_TOKEN=secrets.token_hex(32),SQUIDRA_ACTOR_ID=str(uuid.uuid4()),SQUIDRA_UI_ORIGIN='http://localhost:3000',SQUIDRA_PORT='0',SQUIDRA_DB_PORT=str(port),SQUIDRA_DB_USER='squidra',SQUIDRA_DB_PASSWORD=password,SQUIDRA_DB_NAME='squidra')
        process=subprocess.Popen([str(prefix/'bin/squidra'),'serve'],cwd=directory,env=service_env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        try:
            bound=wait_banner(process,'SQUIDRA listening 127.0.0.1:')
            assert get(bound,'/health')==(200,b'{"status":"alive"}')
            status,body=get(bound,'/ready');assert status==200 and json.loads(body)=={'status':'ready'}
            assert get(bound,'/api/v1/unknown')[0]==401
        finally:stop(process)
        print('SQUIDRA_TEST_PASS:installed_server_database')
        web=subprocess.Popen(['node',str(prefix/'share/web/serve.mjs')],cwd=directory,env=dict(env,SQUIDRA_WEB_PORT='0'),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        try:
            port=wait_banner(web,'SQUIDRA web listening 127.0.0.1:')
            for path in ['/','/import','/questions','/questions/app.js','/questions/protocol.js','/timeline','/approvals','/style.css']:
                status,body=get(port,path);assert status==200 and body
        finally:stop(web)
        print('SQUIDRA_TEST_PASS:installed_web')
        extra=prefix/'user-data';extra.write_text('keep me')
        try:pkg.uninstall(prefix);raise AssertionError('User data removed')
        except ValueError:pass
        assert extra.read_text()=='keep me';extra.unlink()
        binary=prefix/'bin/squidra';old=binary.read_bytes();binary.write_bytes(old+b'changed')
        try:pkg.uninstall(prefix);raise AssertionError('Modified executable removed')
        except ValueError:pass
        assert binary.exists();binary.write_bytes(old)
        pkg.uninstall(prefix);assert not prefix.exists()
        print('SQUIDRA_TEST_PASS:safe_uninstall')
        # Authored malicious archives with matching outer digest still cannot
        # escape the fresh prefix or carry links/duplicates/unlisted payloads.
        for archive_name,mode,duplicate in [('../escape',stat.S_IFREG,False),('bin/squidra',stat.S_IFLNK,False),('bin/squidra',stat.S_IFREG,True)]:
            m={'format':1,'target':pkg.target(),'source_commit':'a'*40,'source_dirty':False,'files':{archive_name:{'sha256':pkg.sha(b'x'),'size':1,'mode':0o755}}}
            buf=io.BytesIO()
            with zipfile.ZipFile(buf,'w') as z:
                info=zipfile.ZipInfo(archive_name);info.external_attr=(mode|0o755)<<16;z.writestr(info,b'x')
                if duplicate:z.writestr(info,b'x')
                z.writestr('manifest.json',json.dumps(m))
            bad=temp/'bad.zip';bad.write_bytes(buf.getvalue())
            try:pkg.install(bad,prefix,pkg.sha(buf.getvalue()));raise AssertionError('Unsafe archive accepted')
            except ValueError:pass
            assert not prefix.exists() and not (temp/'escape').exists()
        for wrong_target,wrong_content in [(True,False),(False,True)]:
            m={'format':1,'target':'unsupported-target' if wrong_target else pkg.target(),'source_commit':'a'*40,'source_dirty':False,'files':{'bin/squidra':{'sha256':pkg.sha(b'x'),'size':1,'mode':0o755}}}
            buf=io.BytesIO()
            with zipfile.ZipFile(buf,'w') as z:
                z.writestr('bin/squidra',b'y' if wrong_content else b'x')
                z.writestr('manifest.json',json.dumps(m))
            bad=temp/'bad.zip';bad.write_bytes(buf.getvalue())
            try:pkg.install(bad,prefix,pkg.sha(buf.getvalue()));raise AssertionError('Wrong target or payload accepted')
            except ValueError:pass
            assert not prefix.exists()
        print('SQUIDRA_TEST_PASS:unsafe_archives_rejected')
        print(json.dumps({'target':pkg.target(),'archive_sha256':built['sha256'],'source_commit':built['source_commit'],'source_dirty':receipt['source_dirty'],'files':built['files']}))
finally:
    if identity:
        data=json.loads(run([engine,'inspect',identity]).stdout)[0]
        if data['Config']['Labels'].get('io.squidra.install-test')!=nonce:raise AssertionError('Ownership mismatch')
        run([engine,'rm','-f',name])
        remaining=run([engine,'ps','--all','--filter','id='+identity,'--format','{{.ID}}']).stdout.strip()
        if remaining:raise AssertionError('Owned container cleanup incomplete')
if not external_db: print('SQUIDRA_TEST_PASS:owned_cleanup')
