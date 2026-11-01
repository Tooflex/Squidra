#!/usr/bin/env python3
"""Build a local macOS ARM64 developer package; no release publication/signing."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import tempfile
import stat
import subprocess
import zipfile

root=Path(__file__).resolve().parents[1]
if platform.system()!='Darwin' or platform.machine()!='arm64': raise SystemExit('Only macOS ARM64 is currently qualified for this builder')
subprocess.run(['swift','build','-c','release','--product','squidra','--force-resolved-versions'],cwd=root,check=True)
subprocess.run(['npm','run','build'],cwd=root/'web',check=True)
bin_dir=Path(subprocess.check_output(['swift','build','-c','release','--show-bin-path','--force-resolved-versions'],cwd=root,text=True).strip())
commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
files={}
def add(path,name,mode=0o644):
    if path.is_symlink() or not path.is_file(): raise ValueError('Payload must be a regular file')
    if name in files: raise ValueError('Duplicate payload')
    files[name]=(path.read_bytes(),mode)
# Stage the executable, bundle Swift compatibility runtime libraries, and remove
# toolchain-only search paths. Never modify the compiler's original artifact.
with tempfile.TemporaryDirectory(prefix='squidra-package-runtime-') as directory:
    stage=Path(directory);binary=stage/'squidra';shutil.copy2(bin_dir/'squidra',binary)
    load_commands=subprocess.check_output(['/usr/bin/otool','-l',str(binary)],text=True)
    rpaths=re.findall(r'cmd LC_RPATH\n\s*cmdsize \d+\n\s*path (.*?) \(offset',load_commands)
    developer_paths=[p for p in rpaths if p.startswith('/Applications/Xcode') and '/usr/lib/swift' in p]
    if any(p not in ['/usr/lib/swift','@loader_path']+developer_paths for p in rpaths): raise ValueError('Unqualified runtime search path')
    command=['xcrun','swift-stdlib-tool','--copy','--scan-executable',str(binary),'--platform','macosx','--destination',str(stage)]
    for path in developer_paths: command += ['--source-libraries',path]
    subprocess.run(command,check=True)
    for path in developer_paths: subprocess.run(['/usr/bin/install_name_tool','-delete_rpath',path,str(binary)],check=True)
    subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(binary)],check=True)
    subprocess.run(['/usr/bin/codesign','--verify',str(binary)],check=True)
    add(binary,'bin/squidra',0o755)
    for path in stage.glob('*.dylib'): add(path,'bin/'+path.name,0o755)
for bundle in bin_dir.glob('*.bundle'):
    for path in bundle.rglob('*'):
        if path.is_file(): add(path,'bin/'+str(path.relative_to(bin_dir)))
for path in (root/'Migrations').rglob('*.sql'): add(path,'share/migrations/'+str(path.relative_to(root/'Migrations')))
for path in (root/'web/dist').rglob('*'):
    if path.is_file(): add(path,'share/web/dist/'+str(path.relative_to(root/'web/dist')))
add(root/'web/serve.mjs','share/web/serve.mjs')
add(root/'packaging/README.md','share/README.md')
for checkout in (root/'.build/checkouts').iterdir():
    if checkout.is_dir():
        for pattern in ['LICENSE*','NOTICE*','COPYRIGHT*']:
            for path in checkout.rglob(pattern):
                if path.is_file() and not path.is_symlink():
                    name='share/licenses/'+checkout.name+'/'+str(path.relative_to(checkout))
                    if name not in files: add(path,name)
dirty=bool(subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip())
manifest={'source_dirty':dirty,'format':1,'target':'darwin-arm64','source_commit':commit,'files':{name:{'sha256':hashlib.sha256(data).hexdigest(),'size':len(data),'mode':mode} for name,(data,mode) in sorted(files.items())}}
out=root/'.build/packaging';out.mkdir(parents=True,exist_ok=True)
archive=out/('squidra-darwin-arm64-'+commit[:12]+'.zip')
with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED) as z:
    for name,(data,mode) in sorted(files.items()):
        info=zipfile.ZipInfo(name);info.external_attr=(stat.S_IFREG|mode)<<16;z.writestr(info,data,compress_type=zipfile.ZIP_DEFLATED)
    info=zipfile.ZipInfo('manifest.json');info.external_attr=(stat.S_IFREG|0o600)<<16;z.writestr(info,json.dumps(manifest,sort_keys=True).encode())
checksum=hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_suffix('.sha256').write_text(checksum+'  '+archive.name+'\n')
print(json.dumps({'archive':str(archive),'sha256':checksum,'files':len(files),'source_commit':commit}))
