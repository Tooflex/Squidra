# Linux browser isolation

## Current qualification

`python3 Scripts/sandbox/qualify.py` builds and exercises a real non-root Chromium
container. `bash Scripts/test-issue.sh SQD-012-ENGINE` records the same checks in
the strict issue runner. Docker must already be configured and available to the
trusted operator. The script never installs a daemon or changes its settings.

This is the engine qualification layer of #12 / #258. The Swift SandboxPort,
bounded user-request adapter and cancellation contract are still to be implemented.
The qualification script accepts no user document or URL and is **not** a task
execution endpoint. Its subprocess output capture is suitable only for its fixed,
authored probes. Do not expose it to model-generated commands or arbitrary HTML.

The observed engine is Docker 29.5.2 on Linux arm64, kernel 6.8.0-117-generic,
inside the existing Colima VM. The control script ran on macOS. This verifies a
Linux container boundary, not native macOS/Windows browser sandboxing, x86_64
Linux, multi-host isolation or a production security certification.

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
