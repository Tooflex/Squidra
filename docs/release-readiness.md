# Local release invariant report

Run from a **clean Git checkout**, with the repository's normal local toolchain
and PostgreSQL test engine available:

```sh
SQUIDRA_CONTAINER_ENGINE="$PWD/Scripts/colima-test-engine.py" \
SSL_CERT_FILE=/etc/ssl/cert.pem bash Scripts/release-check.sh --profile=offline
```

The certificate file above is the macOS system trust store used by the local
Semgrep installation. Use the host's normal trust configuration on other systems.
This command starts fresh checks; it never imports a previous successful report.
It makes no paid provider calls. The dependency security scanner may query OSV
with dependency metadata as documented in the security gate. Other profiles are
rejected before execution. `T09-INVARIANTS` maps to the same command.

## Scope and evidence

| Gate | Existing executable evidence |
| --- | --- |
| Report contracts | Reject incomplete/empty/mismatched counts, failed commands, skipped/duplicate XML and source changes |
| `SQD-009` | Approval gateway, denied/withdrawn/expired continuation, exact-command and route contracts |
| `SQD-007` | Canonical fingerprints and durable action ledger/idempotency |
| `T14-RUN` | Validated planning, scoped reads, grounded citations, request correlation and failure paths |
| `SQD-028` | Runtime checkpoints, approval waits, durable reconciliation, effect-process crashes, ownership, publication and automatic host recovery |
| `SQD-031` | Frozen annotated component and PostgreSQL query datasets, actual predictions and thresholds |
| `T09-LATENCY-CONTRACTS` / `T09-LATENCY` | Quantile regressions, raw scripted-runtime samples and separate tool-free model-port overhead |
| `T08-FAKE-MODEL` | Historical replay, one notification, process reproduction, scripted questions and negative cases |
| `SQD-035` | Dependency analysis, targeted SAST, tracked secret scan and Swift lint, with their negative contracts |

Reports live in a unique private `.build/release-checks/<run>/` directory.
`report.json` contains UTC start/end time, platform, Git commit, clean-state check,
all tracked source hashes, per-suite exit codes, exact selected/passed/failed/
skipped/unexecuted counts, wall duration and log hashes. Available XCTest XML is
copied and checked for complete unique successful cases. Command-suite stdout and
fresh saved summaries must agree. Evaluations copy results, predictions, baseline
and thresholds with their hashes and verified Git provenance. Private full logs
remain local; the command prints only progress, report location and completion
markers. No key or real-provider opt-in is passed to child processes.

A nonblocking lock prevents concurrent runs of this release command. Do not run
other test suites against the shared `.build/issue-tests` report paths during it.
Any failed command, invalid report or source change makes the gate fail. The
report preserves failed and not-executed steps. All ten completion markers are
emitted only after all gates and the final clean-source comparison succeed.

## What a passing gate does and does not establish

The existing tests assert refusal after denial/expiry, idempotent effects, binding
and validation of calls, and explicit tested recovery paths. Suite pass counts
are **not** measured domain-event totals; this report does not invent a percentage
or universal production guarantee from them. Inspect the named tests and copied
logs for each invariant's tested scope. The full Bootstrap campaign is a separate
check (`python3 Scripts/check-local.py`); this targeted release report does not
claim to repeat every Bootstrap suite or every supported platform.

Quality thresholds remain scoped to the frozen authored datasets: temporal
accuracy >=0.90, spatial accuracy >=0.85 and component movement F1 >=0.85.
Repeated deterministic cases are not independent AI trials or general real-world
perception accuracy. The scripted-model demo is explicitly not real inference.
Existing real Meta/SAM qualification receipts are separate dated evidence and
are not revalidated by this command.

`gateStatus: passed` still records **`releaseStatus: not_ready`**. This component
implements the invariant-report and selected offline latency portions of #45. Full #44/#42 demo
acceptance, remaining #48 data-lifecycle
requirements, final hosted CI qualification and explicit epic acceptance remain
outstanding. Suite wall times include setup/build/test overhead and must never be
presented as request latency. No SLA is invented. No automatic release, CI change
or issue closure occurs.


The report now also copies offline latency raw samples, summary and verification
receipt, checks their commit and hashes, and recomputes their statistics. Runtime
p50/p95 use real PostgreSQL with a scripted model; the separate model-port median
has no tool execution. Timing boundaries and limitations are documented in
[the demo profile](demo.md#offline-latency-profile). Neither is a measured
end-to-end tool-free product question or Meta inference time. No pass threshold
is imposed on these latency values; validity and completeness are checked.

## Confirmed latency scope — 2 November 2026

The maintainer selected measurement of the model call for the tool-free latency
criterion in #45. A new question workflow without world reads is not required.
The existing offline model-port fixture is the selected baseline; it does not
measure Meta inference, HTTP or browser latency.

On clean commit `8b245c58c7bd6bed111a08579ca716b43a75dd01`, the 30 retained samples
after three warmups gave model-port median/p50 **0.005813 ms** and p95
**0.00665595 ms**. The separate PostgreSQL/scripted-runtime series gave median/p50
**48.5456045 ms** and p95 **60.1067333 ms**, on Darwin 27 ARM64 in a debug build.
No SLA or general model-performance claim follows from these fixture timings.

The ten-group report is `.build/release-checks/f80e51a6a33043768635cdffabd5812c/report.json`,
SHA-256 `26c84317d39a5ec15c9a53624bd7ee209e9491174c8c7d88ec88f8b9b3e91bde`.
Its stored metrics and hash were rechecked when recording this decision; no new
benchmark or paid call was run. The selected latency criterion is satisfied by
this evidence. The other #45 dependencies and final hosted CI qualification
remain outstanding, so `releaseStatus: not_ready` remains correct.
