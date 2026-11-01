# Local native package — SQD-002

These are macOS and Linux ARM64 developer packages, not public production releases.
Its manifest identifies the source commit and whether the checkout was dirty. The server still reports its
existing development version; the package does not invent a release version.
On macOS the staged executable has an ad-hoc linker/developer signature, no
Developer ID or notarization. Toolchain-only runtime search paths are removed;
required Swift compatibility libraries are copied beside the executable. On
Linux the Swift standard library is linked statically, and debug symbols are
stripped from a staged copy. OS libraries remain dynamic dependencies.
No installer changes system directories, launch agents, PATH, Keychain,
quarantine or Gatekeeper settings. No Apple Container dependency is used.

Build with `python3 packaging/build.py` using the pinned Swift and Web toolchains.
The builder includes the optimized native server, adjacent Swift resource
bundles and compatibility runtime libraries, static Web assets and loopback Node server, SQL migrations, and
available dependency license/notice files. PostgreSQL, PostGIS, pgvector, Node
and Python are prerequisites; they are not silently installed. Repository
source licensing and release approval remain separate from local qualification.

Install into a new directory under an operator-controlled private parent:

```sh
python3 Scripts/install/package.py install ARCHIVE.zip NEW_PREFIX --sha256 EXPECTED_SHA256
NEW_PREFIX/bin/squidra --help
NEW_PREFIX/bin/squidra --version
node NEW_PREFIX/share/web/serve.mjs
python3 Scripts/install/package.py uninstall NEW_PREFIX
```

Obtain the expected SHA-256 from a trusted build record. A checksum detects
corruption; a checksum distributed with an archive is not publisher identity
or notarization. The installer checks target, file inventory, bounds, hashes
and paths, and rejects links, duplicates and an existing installation prefix.
It does not run archive-supplied installation scripts. Uninstall refuses
modified or extra files, preserving user data rather than deleting them.
Keep application configuration, run directories, private keys and database
storage outside the installation prefix. Stop the service before uninstalling.

Configure the server with the environment documented by `squidra --help` and
apply the packaged SQL migrations using the repository's controlled migration
procedure against a prepared database. The package does not initialize or
migrate an existing database automatically. The default model profile remains
offline. The optional Linux browser sandbox is a separately qualified service,
not embedded in this native package.

## Qualification matrix

| Target | Packaging status |
| --- | --- |
| macOS 27.0.1 (26A434), ARM64 | Local developer package installation, real service smoke and uninstallation tested |
| Ubuntu 24.04.5 LTS, ARM64, container kernel | Native package installation, real service smoke and uninstallation tested without Swift toolchain |
| Windows | Target only; not qualified and excluded from CI by maintainer request |

Only an actually executed package installation/smoke/uninstallation qualifies
a row. General Swift compilation or container tests do not establish native
package support on a different platform. T09/MVP release acceptance remains
outstanding; this package is not a production-readiness claim.

## Local verification — 1 November 2026

`SQUIDRA_CONTAINER_ENGINE="$PWD/Scripts/colima-test-engine.py" bash Scripts/test-issue.sh SQD-002`
executes seven strict checks: SHA-256-verified installation without overwrite;
installed native help/version and signature/runtime-path inspection; installed
server health, PostgreSQL readiness and authentication on loopback; eight
installed Web routes/assets; safe uninstall refusing user additions or modified
files; malicious/traversal/link/duplicate/target/hash rejection; and confirmed removal
of the owned database container. It uses
private temporary installation/configuration and an owned temporary database.

The build used Swift 6.4.2, Node 26.10.0 and the current macOS SDK. The binary is
thin ARM64, with an ad-hoc signature and no Developer ID. `otool` inspection
found system libraries plus Swift CompatibilitySpan; the latter is now bundled
beside the staged executable and the Xcode-only rpath is removed. The live
service test runs that installed binary outside the checkout with a minimal
environment. Other macOS versions, other Linux distributions/architectures, Windows,
Gatekeeper notarization, and production release acceptance are not qualified.

## Linux qualification

Run `bash Scripts/test-issue.sh SQD-002-LINUX` from a clean candidate commit.
It clones only committed repository history into an isolated build directory,
builds with the pinned Swift 6.4.2 and Node 26.10.0 ARM64 image manifests, then
installs the archive in a separate Ubuntu 24.04 runtime image. The runtime has
neither a Swift compiler nor access to the source tree or compiler cache.
Its network namespace is shared with an owned PostgreSQL test container whose
network is disabled; no host database port is published. The same six install,
CLI, service, Web, uninstall and malicious-archive checks run as on macOS, plus
verified cleanup of all owned containers. No Apple Container is involved.

Runtime prerequisites: Python 3 for the installer; Ubuntu `libcurl4t64` and
`libstdc++6` for the native executable; Node 26.10.0 plus `libatomic1` for the
Web server; and the prepared PostgreSQL/PostGIS/pgvector database described
above. These are explicit prerequisites, not software silently installed by
the package. The test Dockerfile supplies them only inside disposable images.
The binary is not fully static. Ubuntu container qualification does not test
systemd integration, a bare-metal installer, other distributions or CPU types.

Artifacts and SHA-256 sidecars are in `.build/linux-package/artifacts/`;
`.build/linux-package/qualification.json` records the source commit, archive
checksum and actual builder/runtime image IDs. Apt dependencies are not
byte-pinned, so this is not a byte-for-byte reproducibility claim. The initial
build was killed with four compiler jobs; two jobs completed. The original
ELF with debug information exceeded the existing 128 MiB per-file limit;
staging and stripping debug symbols fixes this without weakening installer
limits. Mac and Linux installers retain the same archive bounds and path checks.
