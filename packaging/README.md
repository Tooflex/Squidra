# Local native package — SQD-002

This is a macOS ARM64 developer package, not a signed/notarized public release.
Its manifest identifies the source commit and whether the checkout was dirty. The server still reports its
existing development version; the package does not invent a release version.
The staged executable has an ad-hoc linker/developer signature, no Developer ID
or notarization. Toolchain-only runtime search paths are removed; required
Swift compatibility libraries are copied beside the executable.
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
| Linux | Application target; native package not yet qualified |
| Windows | Target only; not qualified and excluded from CI by maintainer request |

Only an actually executed package installation/smoke/uninstallation qualifies
a row. General Swift compilation or container tests do not establish native
package support on a different platform. T09/MVP release acceptance remains
outstanding; this package is not a production-readiness claim.

## Local verification — 1 November 2026

`SQUIDRA_CONTAINER_ENGINE="$PWD/Scripts/colima-test-engine.py" bash Scripts/test-issue.sh SQD-002`
executes six strict checks: SHA-256-verified installation without overwrite;
installed native help/version and signature/runtime-path inspection; installed
server health, PostgreSQL readiness and authentication on loopback; eight
installed Web routes/assets; safe uninstall refusing user additions or modified
files; and malicious/traversal/link/duplicate/target/hash rejection. It uses
private temporary installation/configuration and an owned temporary database.

The build used Swift 6.4.2, Node 26.10.0 and the current macOS SDK. The binary is
thin ARM64, with an ad-hoc signature and no Developer ID. `otool` inspection
found system libraries plus Swift CompatibilitySpan; the latter is now bundled
beside the staged executable and the Xcode-only rpath is removed. The live
service test runs that installed binary outside the checkout with a minimal
environment. Other macOS versions, Linux packages, Windows packages, Gatekeeper
notarization, and production release acceptance have not been qualified.
