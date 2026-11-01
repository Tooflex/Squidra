# Linux ownership qualification

On 2026-11-01, the full `squidra` release product built successfully with Swift
6.4.2 on Ubuntu Noble ARM64, using `--force-resolved-versions
--static-swift-stdlib -j 4`. Its `--help` ran successfully and `ldd` resolved
all dependencies in the build image. This is not a fully static executable:
libcurl, libc and other system libraries remain runtime dependencies.

The previous native build failed because Swift Glibc does not expose the
`statfs`/`fstatfs` declarations used by ownership recovery. `CSquidraPlatform`
now encapsulates this descriptor-based check, preserving the existing Linux
filesystem allowlist and macOS MNT_LOCAL policy. Unknown filesystems remain
unsupported; syscall failure remains unavailable. No external package is added.

Run `bash Scripts/test-issue.sh SQD-269-LINUX` with Docker available. The test
image uses the official Swift 6.4.2 Noble ARM64 manifest pinned in
`linux-swift.Dockerfile`, plus Python for the existing child-process fixture.
See the [official Swift Docker installation instructions](https://www.swift.org/install/linux/docker/).
Python packages are not byte-pinned, so the report records the actual image ID.
The script copies exact production and test files into an isolated focused
Swift package and records their SHA-256 hashes. Network access is disabled
for the test container. Five exact XCTest cases must pass with zero failures;
Linux XCTest console results are checked because this runner does not emit
Swift Testing's xUnit file. The owned container is removed and absence verified
before emitting the success marker.

Observed: five ownership tests passed on Linux ARM64 and five passed in the
full macOS package via `SQD-028-OWNERSHIP`, including actual kernel lock release
on child-process death. Reports and logs are under `.build/linux-qualification`.
This focused test does not qualify the entire Linux application test suite,
installation package, service/database behavior, other architectures or Windows.
Those remain separate acceptance work under #2.
