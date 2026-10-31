# Development bootstrap (T01)

## Toolchain and dependencies

- Swift **6.4.2**, Swift 6 language mode; `Package.swift` requires tools 6.4.
- Hummingbird **2.28.1**, exact dependency. All transitive revisions and
  versions are committed in `Package.resolved`.
- Hosted macOS CI selects Xcode **26.3** explicitly for its Foundation SDK;
  the macos-15 image defaults to Xcode 16.4, which cannot compile the
  resolved swift-configuration API usage. The Swift compiler remains 6.4.2.
- Python 3.10+ and Bash for the issue test runner; no Python packages are
  required. The Swift tests use the toolchain's XCTest.
- macOS deployment minimum: 14. This is a deployment declaration, not a
  claim that every macOS version or architecture was tested.

Versions were checked against the official
[Swift release](https://github.com/swiftlang/swift/releases/tag/swift-6.4.2-RELEASE)
and [Hummingbird release](https://github.com/hummingbird-project/hummingbird/releases/tag/2.28.1).
CI checkout is pinned to a commit SHA. The CI installer downloads the exact
official Swift 6.4.2 archive/package and verifies its GPG/package signature;
it does not rely on setup-swift v2, whose version table stops at 6.2.1.
Official toolchain downloads were checked for availability. Installation
is restricted to disposable GitHub Actions runners.
Dependency upgrades require updating
both the exact declaration (when applicable) and the lockfile in a reviewed PR.

## Package products and boundaries

- `SquidraDomain`: library with the first real invariant, finite confidence
  in `[0, 1]`; unknown confidence must be represented separately.
- `squidra` / `SquidraServer`: executable composition-root placeholder.
  It currently prints a bootstrap message and exits. It does not open
  an HTTP listener or implement probes; those belong to SQD-001.
- Application boundaries: AgentRuntime, Cognition, Temporal, Spatial,
  World, Perception, Memory, Security, Tools, Protocols, Observability.
  Their targets depend only on Domain at bootstrap; source files mark
  boundaries and do not claim implemented features.
- Adapters: Postgres depends on Domain/World; Meta on
  Domain/Cognition/Perception. The server connects the adapters and
  application targets with Hummingbird. No SQL driver or model SDK is
  introduced here.

The manifest is acyclic. Domain has no package, HTTP, SQL, or model SDK
dependencies. Future changes must preserve the accepted
[port contracts](adr/0005-swift-ports.md).

## Build and verify

From the repository root:

```bash
swift --version
swift build --force-resolved-versions
bash Scripts/test-issue.sh T01
swift run --skip-build squidra
```

`python3 Scripts/test_issue_runner.py` checks eight process/report scenarios
using an isolated fake Swift command, including exit-code preservation,
stale-report removal, missing/partial reports, and fully skipped suites.
These checks test the runner and do not substitute for the real Domain tests.

The runner builds/discovers XCTest cases, applies the issue's regex,
requires a nonempty selection, executes it with two parallel XCTest workers
(SwiftPM emits xUnit reports in parallel mode), and inspects the actual xUnit
report. It preserves SwiftPM's failure exit code and fails if no tests
execute, the report is missing/malformed, tests are omitted, or tests
fail. Skipped tests are counted separately and never counted as passed.
A fully skipped selection fails. Reports are under
`.build/issue-tests/<issue>/`; stale reports are removed before discovery.

`Scripts/issue-tests.json` registers explicit XCTest or integration-command
suites. Unmapped issues fail. Command suites must emit every unique mapped
`SQUIDRA_TEST_PASS:<name>` marker after executing its assertion; partial,
unknown, duplicate, or missing markers cannot pass, and process failures
are preserved. Swift Testing requires separate discovery/report support.

Negative checks:

```bash
# Both commands must fail; neither is a successful application test.
bash Scripts/test-issue.sh T01 --filter '^MissingSuite/'
bash Scripts/test-issue.sh T99
```

Filters use the regex subset shared by Python and SwiftPM. Empty or
invalid filters fail; the runner also checks discovered versus reported
case counts to catch selection mismatches.

## Platform qualification

| Environment | Qualification |
|---|---|
| Local macOS ARM64 (macOS 27), Swift 6.4.2 | `swift build`, 4 Domain tests, 8 runner checks, and executable smoke passed on 31 October 2026 |
| Ubuntu 24.04 x86_64, Swift 6.4.2 | Build, Domain tests, runner checks, negative selection, executable smoke and lockfile check passed in run 41193634931 |
| macOS 15 ARM64 hosted runner, Swift 6.4.2, Xcode 26.3 | Build, Domain tests, runner checks, negative selection, executable smoke and lockfile check passed in run 41193896734 |
| Windows x86_64 | Unqualified: the first hosted probe found no Swift executable (run 41193488750) |
| Linux ARM64, macOS x86_64 outside the observed CI runner | Not tested by this bootstrap |
| Windows ARM64 | Deferred |

Do not infer support from a matrix entry, successful package resolution,
or a workflow's overall success when a probe is nonblocking. No database,
model access, container runtime, API key, or external telemetry is required
for the Domain tests. Package fetching requires network access once.

## CI and required checks

`.github/workflows/bootstrap.yml` runs the Linux/macOS build, issue tests,
empty-selection negative check, executable smoke test, and lockfile check.
Windows qualification is reported separately and cannot certify support
by being marked nonblocking. Workflows declare `contents: read`, do not
persist checkout credentials, and never use `pull_request_target`.

After the real Linux/macOS jobs run successfully, their observed check
names can be made required on `main`. Do not require invented check
names or the nonblocking Windows probe. The maintainer requested no
mandatory GitHub reviewers; the PR and history protections in
[the bootstrap workflow](github-bootstrap.md) remain in effect.

## PostgreSQL world schema (T02)

The database image pins the multiarchitecture PostgreSQL base by manifest
digest and PGDG extension package versions. Qualified locally on Linux
ARM64 in Podman: PostgreSQL 17.11, PostGIS 3.6.4 and pgvector 0.8.7.
The Linux CI database job separately verifies AMD64. Debian transitive
packages come from signed repositories; the final built image itself is
not published or claimed bit-for-bit reproducible.

```bash
bash Scripts/dev-db.sh build
bash Scripts/test-issue.sh T02
bash Scripts/dev-db.sh up
bash Scripts/dev-db.sh migrate
bash Scripts/dev-db.sh down
```

Docker or Podman must already be running. `SQUIDRA_CONTAINER_ENGINE` can
select an explicit engine executable. The helper never initializes or
resets a VM, publishes a host port, or deletes the development data volume.
The integration test uses a unique, labelled, network-isolated container,
a random credential file, and temporary data; cleanup targets only that
container. Development credentials are generated into the gitignored
`infra/.env.squidra-db` with mode 0600 and never printed.

The Compose alternative also publishes no host ports and requires a
random `SQUIDRA_DB_PASSWORD` supplied outside version control. Its named
volume is separate from the CLI helper's volume; do not switch between
these interfaces expecting automatic data/credential migration.

Migrations in `Migrations/world` and then `Migrations/runtime` execute
inside one advisory-locked transaction. Applied filenames and SHA-256
checksums are recorded. Repeating the same migrations does nothing;
editing an applied migration fails and rolls back. Add a forward
migration instead. Tests verify a forced DDL failure leaves neither the
new table nor migration metadata behind.

World tables enforce actor-scoped foreign keys, bounded confidence,
finite timestamps, positive stored fact/transaction intervals, and
append-only journal/link rows. Journal entity arrays are authoritative;
derived links are inserted atomically and cannot add undeclared entities.
Correction uses a new event and may update projections, never raw history.
The local database owner is a trusted development superuser; these
triggers are not claimed to resist a database administrator who can
disable them. Production role grants and the Swift storage adapter are
separate work. No model embedding dimension is invented by this schema.
