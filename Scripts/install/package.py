#!/usr/bin/env python3
"""Checksummed private-prefix install; no privileged writes or post-install code."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import sys
import zipfile

MAX_ARCHIVE=268435456

def sha(data): return hashlib.sha256(data).hexdigest()
def target(): return platform.system().lower()+'-'+platform.machine().lower()

def manifest(raw):
    if len(raw)>1048576: raise ValueError('Manifest too large')
    value=json.loads(raw)
    if set(value)!={'format','target','source_commit','source_dirty','files'} or type(value['source_dirty']) is not bool or value['format']!=1 or value['target'] not in ['darwin-arm64','linux-aarch64'] or value['target']!=target() or not re.fullmatch('[0-9a-f]{40}',value['source_commit']): raise ValueError('Unsupported manifest')
    files=value['files']
    if not isinstance(files,dict) or not 1<=len(files)<=2048 or 'bin/squidra' not in files: raise ValueError('Invalid file inventory')
    total=0
    for name,entry in files.items():
        path=PurePosixPath(name)
        if not isinstance(name,str) or name!=str(path) or path.is_absolute() or len(path.parts)>16 or any(x in {'','..','.'} for x in path.parts) or '\\' in name or '\x00' in name or path.parts[0] not in {'bin','share'}: raise ValueError('Unsafe archive path')
        if set(entry)!={'sha256','size','mode'} or not isinstance(entry['sha256'],str) or not re.fullmatch('[0-9a-f]{64}',entry['sha256']) or type(entry['size']) is not int or not 0<=entry['size']<=134217728 or entry['mode'] not in [0o644,0o755]: raise ValueError('Invalid file metadata')
        total+=entry['size']
    if total>MAX_ARCHIVE: raise ValueError('Package too large')
    return value

def install(archive,prefix,expected):
    if not re.fullmatch('[0-9a-f]{64}',expected): raise ValueError('Expected SHA-256 required')
    if archive.stat().st_size>MAX_ARCHIVE: raise ValueError('Archive too large')
    with archive.open('rb') as stream: raw=stream.read(MAX_ARCHIVE+1)
    if len(raw)>MAX_ARCHIVE: raise ValueError('Archive too large')
    if sha(raw)!=expected: raise ValueError('Archive checksum mismatch')
    import io
    with zipfile.ZipFile(io.BytesIO(raw)) as source:
        infos=source.infolist()
        if len(infos)>2049 or len({x.filename for x in infos})!=len(infos): raise ValueError('Duplicate or excessive entries')
        if 'manifest.json' not in source.namelist() or source.getinfo('manifest.json').file_size>1048576: raise ValueError('Missing manifest')
        raw_manifest=source.read('manifest.json'); data=manifest(raw_manifest)
        if set(source.namelist())!=set(data['files'])|{'manifest.json'}: raise ValueError('Unlisted archive entry')
        for info in infos:
            mode=info.external_attr>>16
            if info.is_dir() or stat.S_IFMT(mode) not in [0,stat.S_IFREG] or info.flag_bits&1: raise ValueError('Unsupported archive entry')
            if info.filename!='manifest.json' and info.file_size!=data['files'][info.filename]['size']: raise ValueError('Size mismatch')
        # Parent is operator-controlled. mkdir exclusively owns a new private prefix.
        prefix.mkdir(mode=0o700)
        try:
            for name,entry in data['files'].items():
                payload=source.read(name)
                if len(payload)!=entry['size'] or sha(payload)!=entry['sha256']: raise ValueError('Payload checksum mismatch')
                path=prefix/name;path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
                with path.open('xb') as output: output.write(payload)
                path.chmod(entry['mode'])
            (prefix/'manifest.json').write_bytes(raw_manifest)
            (prefix/'manifest.json').chmod(0o600)
        except BaseException:
            shutil.rmtree(prefix)
            raise
    return {'status':'installed','target':data['target']}

def uninstall(prefix):
    info=prefix.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077: raise ValueError('Prefix must be private and owned')
    receipt=prefix/'manifest.json'
    if receipt.is_symlink(): raise ValueError('Linked receipt')
    data=manifest(receipt.read_bytes())
    actual=set()
    for path in prefix.rglob('*'):
        if path.is_symlink(): raise ValueError('Unexpected symlink')
        if path.is_file(): actual.add(str(path.relative_to(prefix)))
        elif not path.is_dir(): raise ValueError('Unexpected filesystem object')
    if actual!=set(data['files'])|{'manifest.json'}: raise ValueError('Unlisted files; preserve user data')
    for name,entry in data['files'].items():
        path=prefix/name
        if path.stat().st_size!=entry['size'] or sha(path.read_bytes())!=entry['sha256']: raise ValueError('Modified file; preserve user data')
    # Only the validated inventory is deleted. Never follow symlinks or remove
    # unrelated state directories, configuration, databases or key stores.
    for name in actual: (prefix/name).unlink()
    for path in sorted((p for p in prefix.rglob('*') if p.is_dir()),key=lambda p:len(p.parts),reverse=True): path.rmdir()
    prefix.rmdir()
    return {'status':'uninstalled'}

def main():
    parser=argparse.ArgumentParser();sub=parser.add_subparsers(dest='action',required=True)
    p=sub.add_parser('install');p.add_argument('archive',type=Path);p.add_argument('prefix',type=Path);p.add_argument('--sha256',required=True)
    p=sub.add_parser('uninstall');p.add_argument('prefix',type=Path)
    args=parser.parse_args()
    try:
        report=install(args.archive,args.prefix,args.sha256) if args.action=='install' else uninstall(args.prefix)
        print(json.dumps(report));return 0
    except (ValueError,OSError,KeyError,TypeError,AttributeError,zipfile.BadZipFile,RecursionError):
        print('{"status":"failed","reason":"invalid package, checksum, target, or non-pristine prefix"}');return 1

if __name__=='__main__': raise SystemExit(main())
