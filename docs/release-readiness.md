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
report preserves failed and not-executed steps. All eight completion markers are
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
implements the invariant-report portion of #45. The p50/p95 and median tool-free
latency measurements, full #44/#42 demo acceptance, remaining #48 data-lifecycle
requirements, final hosted CI qualification and explicit epic acceptance remain
outstanding. Suite wall times include setup/build/test overhead and must never be
presented as request latency. No SLA is invented. No automatic release, CI change
or issue closure occurs.
