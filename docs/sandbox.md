# Linux browser isolation

## Current qualification

`python3 Scripts/sandbox/qualify.py` builds and exercises a real non-root Chromium
container. `bash Scripts/test-issue.sh SQD-012-ENGINE` records the same checks in
the strict issue runner. Docker must already be configured and available to the
trusted operator. The script never installs a daemon or changes its settings.

The Swift `SandboxPort` and `DockerBrowserSandbox` now use this engine for bounded
offline HTML rendering. Run `bash Scripts/test-issue.sh SQD-012` for the complete
gate: host contracts, engine confinement and real browser execution through Swift.
The engine qualification script itself still accepts no user document or URL and
is **not** a task endpoint. Its output capture is suitable only for its fixed,
authored probes; arbitrary documents go through the bounded Swift adapter.

The observed engine is Docker 29.5.2 on Linux arm64, kernel 6.8.0-117-generic,
inside the existing Colima VM. The control script ran on macOS. This verifies a
Linux container boundary, not native macOS/Windows browser sandboxing, x86_64
Linux, multi-host isolation or a production security certification.

## Swift host integration

Add the `SquidraSandbox` library to a trusted host. Construct configuration from
operator-controlled paths and the **qualified immutable image ID**, then derive
actor/run/trace identities and authorization from the calling gateway. No default
HTTP endpoint, tool capability or startup activation is added by this library.

```swift
let config = try DockerSandboxConfiguration(
    executable: trustedDockerExecutable,
    socket: trustedLocalDockerSocket,
    imageID: qualifiedImageID,
    seccompProfile: reviewedProfileBytes)
let browser = try DockerBrowserSandbox(configuration: config)
let request = try SandboxRequest(
    actorID: authenticatedActorID, runID: runID, traceID: traceID,
    html: documentBytes, limits: SandboxLimits(),
    deadline: .now.advanced(by: .seconds(30)),
    network: .none, hostAccess: false)
let result = try await browser.render(request)
```

Reuse one host adapter: its shared admission actor allows only one active render,
with immediate `busy` rejection rather than an unbounded queue. Configuration
requires the reviewed profile hash, a content-addressed image ID and an explicit
local Unix daemon socket. Runtime also checks Linux arm64 and image identity.
The host must use an image built and qualified by this repository; a digest alone
does not certify an arbitrary image's contents. There is no implicit image pull.

Requests accept valid, nonempty UTF-8 HTML without NUL, up to 64 KiB. Explicit
limits can tighten memory (256–512 MiB), CPU (0.1–1), tasks (64–128), workspace
(8–32 MiB), input/output bytes and execution time (100–30000 ms). Output is limited
to 1–256 KiB, enforced while reading rather than after allocation. Internet policy
and host access are rejected. The fixed image entrypoint writes stdin to the
private `/work/input.html`, then runs Chromium against that file with its namespace
sandbox active. It never evaluates document text as a shell command. No user
document, URL, environment variable or CLI option is interpolated into host argv.

The host driver executes the configured Docker binary directly with a minimal
explicit environment. It does not inherit provider keys, SSH agents, Docker
contexts or registry credentials. Private 0700 directories / 0600 files carry
stdin and the reviewed profile; documents do not appear in process arguments.
Docker logging is disabled. Stderr is discarded with a 16 KiB bound; stdout has
the requested bound. The fixed host binary must not daemonize while retaining its
stdio pipes. The driver joins its process and readers after cancellation, timeout
or overflow. Arbitrary host executables are not a client-selectable feature.

The deadline includes validation and creation as well as rendering. Cancellation
or failure still performs joined, ownership-checked cleanup under a separate
ten-second deadline. A lost create acknowledgement is reconciled only by the
generated exact name and nonce; destruction uses the verified immutable ID.
If no resource is yet visible after an unacknowledged create, a late daemon commit
cannot be excluded: this also requires reconciliation and retains admission.
An uncertain daemon response or local cleanup failure returns `cleanupRequired`,
never a successful result. That adapter retains its admission slot to prevent an
outage from accumulating orphan containers. The operator must reconcile resources
for the known actor/run before replacing the host adapter; blindly retrying the
request or deleting unrelated resources is not a recovery strategy. Host process
death and cross-host orphan recovery are not qualified by these tests.

Successful results retain actor/run/trace and a generated execution ID. Rendered
DOM is untrusted data, not authorization, proof of a world fact or instructions
for another tool. Persistent browser sessions, external navigation and arbitrary
browser automation commands are outside this first offline port.

The complete gate covers malformed requests, unauthorized network/host access,
quota bounds, concurrent admission, uncertain creation, foreign ownership,
sanitized environment/errors, bounded process I/O, deadline and cancellation.
Real Swift tests verify JS rendering from stdin, output overflow, an infinite-JS
deadline, and cancellation **after observing a running container**, then confirm
no container for that run remains. A real daemon create followed by an injected
lost acknowledgement also verifies exact-name reconciliation and destruction
without starting the browser. The latest runtime report is
`.build/sandbox/adapter-qualification.json`; the earlier public v1 engine report
remains a historical observation of the image before the stdin entrypoint.

Observed runtime qualification on 2026-11-01 at 21:30:37 UTC used image
`sha256:83a2b9c62edb85f805c13accc5859d7ceeb048176d5d6386b37e0eef0eae3265`:
all three suites passed (ten host-contract tests, eight engine checks and four
real Swift browser tests). This is a dated local observation, not a promise that
a later rebuild has the same digest or support matrix.


## Confinement contract

Each probe gets a distinct immutable container ID and UUID ownership label:

- UID/GID 1000, no Linux capabilities, no-new-privileges and a reviewed seccomp
  profile. No privileged mode, host PID/IPC namespace, host bind, device or Docker
  socket is requested. Docker's own generated hostname/resolver files are not a
  grant to mount the user's filesystem.
- Read-only image; private `/work` tmpfs of 32 MiB (UID 1000, mode 0700), `/tmp`
  tmpfs of 64 MiB, and private shared memory of 64 MiB. Writable mounts have
  `nosuid,nodev`; each disappears with its owning container.
- Network `none`, with only loopback. No external network or host-service access
  is enabled. A future online policy must be implemented and verified explicitly;
  this profile must not silently become bridge/host networking.
- Memory 512 MiB, total memory+swap 512 MiB, one CPU, 128 tasks, 1024 open files.
  The tests read actual cgroup limits and privilege status, fill `/work` beyond
  its limit and verify that the next container sees an empty workspace.
- Destruction requires both membership in the invocation's owned-ID set and the
  exact matching ownership nonce. A foreign owner is refused before removal.
  Cleanup never lists or prunes unrelated containers. A lost create acknowledgement
  is reconciled only through that call's generated name and matching label.

Chromium uses its **namespace sandbox**, not the setuid helper. Its diagnostic
page confirms PID/network namespaces and Seccomp-BPF. `--disable-setuid-sandbox`
selects this supported mechanism; `--no-sandbox` is never used. The diagnostic-only
`--allow-chrome-scheme-url` flag permits inspection of `chrome://sandbox`; it must
not be inferred as permission for future untrusted requests to navigate internal
browser pages.

The default Docker profile rejected Chromium's namespace startup. The pinned
Playwright profile allows the required namespace syscalls; this repository adds
an unconditional seccomp allow rule for `chroot`. Without that rule Chromium's
namespace jail failed after all outer capabilities were dropped. The rule grants
no Linux capability: the non-root outer process still cannot mount or access the
host, and the browser uses `chroot` inside its newly created user namespace.
The tests check the resulting browser sandbox, not merely a successful exit.

## Inputs and provenance

- Alpine base digest:
  `sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0`.
- Chromium package: `149.0.7827.53-r0`, from Alpine's configured official package
  repositories. Transitive APK packages are resolved by APK; rebuilding against
  changed repositories is not claimed to reproduce identical bytes. The resulting
  local image ID is resolved once and used for every probe, with no implicit pull.
- Seccomp source: [Playwright at ae935a43](https://github.com/microsoft/playwright/blob/ae935a43d9e376e4759548f6b3c6905c7b282333/utils/docker/seccomp_profile.json),
  reformatted and extended only with the `chroot` rule. Profile SHA-256:
  `e53c15d248f57bceec0a3a16fad1b4ab0d05a7bddb455f86a60e2dba5612cdf7`.
  The upstream Apache-2.0 license is preserved in
  `Scripts/sandbox/LICENSE.playwright`.

The profile must match that reviewed hash before the qualification script runs.
Build logs and the current report are written to `.build/sandbox/`; successful
reports include engine/browser versions, immutable image ID, profile hash and
observed check names. A previous report is deleted before any attempt. The public
dated observation is `fixtures/sandbox/qualification-linux-arm64.v1.json`.
No provider key, cloud inference or paid service is used.

The probes verify actual JavaScript rendering, Chromium's internal sandbox,
cgroup settings, rejection of host sentinel/socket/root writes/mounts, external
and metadata-address network failure, filesystem quota enforcement, workspace
separation and owned-only destruction. They do not establish immunity to browser
or kernel vulnerabilities. Updates require rerunning the checks and reviewing
the observed image/profile rather than weakening the assertions.

Primary references: [Docker resource and runtime constraints](https://docs.docker.com/engine/containers/run/),
[Playwright's namespace/seccomp guidance](https://playwright.dev/docs/docker), and
[Chromium Linux sandbox mechanisms](https://github.com/chromium/chromium/blob/main/sandbox/linux/README.md).
The Playwright container image itself is not used.
