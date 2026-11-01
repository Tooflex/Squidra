#!/usr/bin/env python3
"""Install the checksummed upstream Linux SwiftLint binary into .build only."""
import hashlib
import io
from pathlib import Path
import platform
import urllib.request
import zipfile

artifacts={
    'x86_64':('swiftlint_linux_amd64.zip','caeed6f4a679c35539ffaf124f6c4ab4a8416917f7d8796279dc52b74026059d'),
    'aarch64':('swiftlint_linux_arm64.zip','9ffa52f478e6d8eb485d37d14715ffac90abc81c58f3370d598bf75be05605f8'),
}
if platform.system()!='Linux' or platform.machine() not in artifacts:raise SystemExit('This installer supports Linux ARM64/AMD64 only')
name,digest=artifacts[platform.machine()]
with urllib.request.urlopen('https://github.com/realm/SwiftLint/releases/download/0.65.1/'+name,timeout=60) as response:
    data=response.read(134217729)
if len(data)>134217728 or hashlib.sha256(data).hexdigest()!=digest:raise SystemExit('SwiftLint archive integrity check failed')
with zipfile.ZipFile(io.BytesIO(data)) as archive:
    matches=[info for info in archive.infolist() if info.filename=='swiftlint']
    if len(matches)!=1 or matches[0].file_size>268435456:raise SystemExit('Unexpected SwiftLint archive')
    payload=archive.read(matches[0])
output=Path(__file__).resolve().parents[2]/'.build/swiftlint'
output.mkdir(parents=True,exist_ok=True)
(output/'swiftlint').write_bytes(payload);(output/'swiftlint').chmod(0o755)
print(output)
