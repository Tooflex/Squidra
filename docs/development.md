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
- `squidra` / `SquidraServer`: executable composition root.
  `serve` starts the authenticated local HTTP service; no arguments show
  CLI help without reading credentials or starting services. See SQD-001 below.
- Application boundaries: AgentRuntime, Cognition, Temporal, Spatial,
  World, Perception, Memory, Security, Tools, Protocols, Observability.
  Their targets depend only on Domain at bootstrap; source files mark
  boundaries and do not claim implemented features.
- Adapters: Postgres depends on Domain/World; Meta on
  Domain/Cognition/Perception. The server connects the adapters and
  application targets with Hummingbird. The readiness adapter uses the
  pinned PostgreSQL driver; no live model SDK is introduced.

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

`python3 Scripts/test_issue_runner.py` checks twelve process/report scenarios
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
resets a VM or deletes the development data volume. `up`, `test` and
`test-runtime` publish no ports; explicitly selected `up-local` and client/server
integration modes bind only to loopback.
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

## Runtime persistence (T03)

```bash
bash Scripts/test-issue.sh T03
```

This suite repeats the eleven world checks and verifies nine runtime
persistence groups against real PostgreSQL. Runs use actor-scoped optimistic
versions, monotonic counters and immutable terminal records. The action
ledger reserves `(actor, tool, idempotency key)` atomically, preserves the
original command, rejects conflicting reuse and returns an existing result
on replay, including replay from another run belonging to the same actor.
Scopes are sorted and deduplicated before comparison. Failed and unknown
provider outcomes remain distinct; reserving a row does not execute a tool.

The concurrency check holds the first reservation transaction open, observes
the second database session blocked on a lock, then commits the first and
verifies one created reservation and one replay of the same ledger ID.
Approval records bind immutable command hashes and expiry metadata; outbox
rows enforce actor-scoped deduplication. A rolled-back reservation leaves no
row. These are SQL persistence primitives: the full legal run transition
matrix, authenticated approval resolution using server time, tool gateway,
outbox dispatcher, provider reconciliation and Swift storage adapter remain
separate backlog work. Database access is trusted; arbitrary SQL access is
not an application authorization boundary.

## Local HTTP boundary (T04)

```bash
bash Scripts/test-issue.sh T04
```

`HTTPBoundary` wraps the complete router before route matching, with
`BoundaryContext` carrying a fresh host-generated request UUID and the
configured actor UUID. The host must inject a credential generated from
32 cryptographically random bytes, encoded as lowercase hexadecimal. It is
never supplied by source defaults or returned by configuration diagnostics.
The token's syntax is validated; syntax alone cannot prove entropy. The
configuration supplies `127.0.0.1` as its listener host. HTTP startup and
configuration loading are composed in SQD-001, described below.

Every data/action route, including unknown paths, requires exactly one
valid Bearer header. An actor header cannot change identity. Resource
handlers must call `context.requireActor` before accessing an actor-scoped
resource and pass that authenticated identity to storage. Only exact GET
requests for the four ADR-006 probes bypass authentication; their handlers
must produce minimal, secret-free bodies. They do not bypass origin policy.

An approved UI origin is mandatory and matched exactly. Remote origins
require HTTPS; HTTP is limited to local UI hosts. Wildcards, null origins,
userinfo, paths, queries and fragments are rejected. Preflights allow only
listed methods and headers. CORS never grants cookie credentials. Nonbrowser
clients without an Origin still require authentication for protected routes.
The streaming body collector checks actual bytes without relying on
Content-Length, restores bounded content for route decoding, and runs under
the same monotonic deadline as the handler. Cancellation is cooperative:
adapters and handlers must release I/O on cancellation; this does not kill
uncooperative code or undo an external effect. SSE needs its own bounded
streaming contract in T05 rather than this buffered request/response path.

Errors use the strict ADR-007 v1 envelope and static public messages, never
raw exceptions. Details are omitted pending route-specific filtered schemas.
All responses carry `X-Request-ID` and `Cache-Control: no-store`. PageRequest
validates a default limit of 50, maximum 100, and a positive Int64 journal
cursor; each listing handler must apply it to an actor-filtered query.
T04 tests execute Hummingbird's in-memory router adapter, not a live network
listener. Probe tests use minimal fixtures; they do not certify dependency
readiness, which belongs to SQD-001.

## Swift PostgreSQL readiness adapter (T02 follow-up)

The exact PostgresNIO 1.33.2 driver is locked with the existing dependencies;
SwiftLog 1.16.2 is declared directly at its already locked version to provide
a no-op logger. `LocalDatabaseConfiguration` accepts injected credentials
and a loopback port, never a remote host or a source default password.
Diagnostics redact credential fields. The driver uses a service-managed
pool: run the client once and cancel its run task during shutdown. Queries
and background connection work use disabled logging; raw errors are mapped
to database/migrations readiness classes.

```bash
python3 Scripts/schema-manifest.py --check
bash Scripts/test-issue.sh DB-CLIENT
```

This integration command explicitly publishes a temporary PostgreSQL port
on **127.0.0.1 only**, verifies the binding, injects a random password through
the child environment, migrates a disposable container, and runs three real
Swift tests. The command report counts two integration groups; its nested
`DB-CLIENT-SWIFT` report records the three XCTest cases. Missing database
configuration fails rather than skipping tests. The ordinary `up`, `test`
and `test-runtime` modes continue to publish no ports. None of these helpers
deletes a development volume or resets a container VM.

A readiness check leases one connection, checks PostgreSQL major version 17,
then compares the complete migration filename/checksum set with the binary's
expected manifest. Missing, edited or future migrations fail readiness.
Regenerate `ExpectedDatabaseSchema.swift` with
`python3 Scripts/schema-manifest.py` whenever adding a forward migration;
CI rejects a stale manifest. This verifies migration metadata, not arbitrary
manual DDL drift or production grants.

The check has a monotonic timeout. Cancellation closes only its leased
connection because awaiting an initial SQL response through a NIO future
does not itself guarantee prompt cancellation. Server statement/lock timeouts
provide additional bounds. Tests hold a real exclusive metadata-table lock,
verify timeout and pool recovery, propagate cancellation, reject checksum
mismatch/missing/future metadata, test an unavailable socket, and verify that
a cancelled client cannot serve more queries. The Linux CI Swift job runs
this real integration; macOS CI compiles the same adapter/tests. No WorldStore
or runtime SQL adapter is claimed by this readiness-only follow-up.

## Headless server and lifecycle (SQD-001)

```bash
bash Scripts/dev-db.sh build
bash Scripts/dev-db.sh up-local
set -a
source infra/.env.squidra-db-local
set +a
export SQUIDRA_DB_PORT=5432 SQUIDRA_DB_USER="$POSTGRES_USER"
export SQUIDRA_DB_PASSWORD="$POSTGRES_PASSWORD" SQUIDRA_DB_NAME="$POSTGRES_DB"
export SQUIDRA_AUTH_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
export SQUIDRA_ACTOR_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
export SQUIDRA_UI_ORIGIN=http://localhost:3000
swift run --skip-build squidra check-config
swift run --skip-build squidra serve
```

Run `swift build --force-resolved-versions` first. Keep credentials outside
source control and do not print them or put them in process arguments.
`up-local` explicitly creates a separate persistent database container,
credential file and data volume from isolated `up`; port 5432 binds only to
127.0.0.1. `SQUIDRA_DB_LOCAL_PORT` selects another local DB port; set the
server's `SQUIDRA_DB_PORT` to match. To stop the local DB container while
retaining its data, use
`SQUIDRA_DB_CONTAINER=squidra-dev-db-local bash Scripts/dev-db.sh down`.
Docker/Podman must already be running; the helper does not manage its VM.

The server binds only to 127.0.0.1:8080 by default. `SQUIDRA_PORT=0` requests
an ephemeral port; startup reports the bound loopback port without secrets.
Only the offline profile is available. Configured credentials, actor and UI
origin are required even when the database is down; there is no anonymous
network mode. Optional model integrations do not gate readiness.

GET `/health/live` and `/health` return `{"status":"alive"}`. GET
`/health/ready` and `/ready` return `{"status":"ready"}`, or 503 with only
`status:not_ready` and `dependency:database|migrations`. All other requests
pass through T04 authentication. There are no business endpoints yet.
Requests and idle HTTP connections are bounded. Hummingbird's service group
handles SIGTERM/SIGINT, drains HTTP work and cancels the owned PostgreSQL
client service. Work still depends on cooperative cancellation; no external
effect is manufactured by shutdown.

`bash Scripts/test-issue.sh SQD-001` starts a disposable loopback database,
runs three Swift lifecycle tests on a real Hummingbird listener, then starts
the actual binary twice. It checks authentication/configuration redaction,
stops its own test database to verify live 200 / ready 503, sends SIGTERM and
SIGINT, and verifies zero exit codes and closed listeners. The command report
counts seven groups; the nested Swift report counts three XCTest cases.
The Linux CI job runs this integration. No missing database is silently
skipped, and no data volume is deleted by the test.

## Persisted FSM and host budgets (SQD-005)

```bash
bash Scripts/test-issue.sh SQD-005-UNIT   # deterministic clock/store fixtures
bash Scripts/test-issue.sh SQD-005        # unit suite plus real SQL integration
```

`RunController` is a host-side actor over the async, actor-scoped `RunStore`
port. `PostgresRunStore` persists an internal schema-version-1 checkpoint,
including budgets, iteration fingerprints, retries, state/substate and
terminal reasons. It checks the checkpoint against SQL scalar fields on
load, rejects corrupt/unknown versions, and uses row locking plus an atomic
expected-version update. T03's immutable/monotonic SQL triggers remain in
force. Internal substates are written in the same update as public state.
Checkpoints are limited to 64 KiB and are not the external HTTP RunState DTO.

The public transition matrix follows ADR-002. Protected phases require a
validated proposal, pending attempts must finish before ordinary transitions,
and terminal records never resume. A wait can resume only to VALIDATING;
this does not approve a tool. Approval authentication/TTL and immediately
pre-effect policy revalidation belong to the gateway/approval integration.
The controller performs no real tool action, model call or outbox dispatch.

The host allows at most 20 validated steps, 15 tool attempts including
retries, depth 3, two retries for the current invocation and 180,000 active
milliseconds. Profiles can tighten these ceilings. Retry backoff is 500 ms
then 1,000 ms after a recorded retryable outcome; every retry preserves the
invocation's idempotency key. Unknown outcomes require reconciliation and
cannot grant a blind retry. Reserved attempts count even when persistence
latency exhausts the remaining active budget before dispatch.

Active accounting uses the injected monotonic clock and rounds consumed
fractions up to milliseconds at checkpoints. Wall-clock jumps do not exhaust
this budget; persisted UTC deadlines are advisory transport/correlation
values. The dispatch permit also has an absolute monotonic deadline, which
the future gateway must enforce. Timeouts and limit terminal reasons are
computed from counters; callers cannot forge an unexhausted timeout/limit.
A lost write acknowledgement detaches the controller so an unconfirmed
checkpoint cannot issue another permit.

At iteration boundaries, three identical no-progress fingerprints terminate
as BUDGET_EXCEEDED / LOOP_DETECTED. Rejected proposals count for repetition
but consume no step. Fingerprints and counts survive storage/restart. The
caller is trusted host code and must supply a canonical semantic digest
excluding incidental IDs, timestamps and idempotency keys. Only
contract-verified new evidence or confirmed relevant effects reset the guard;
provider text or bookkeeping cannot be promoted to progress. Canonical tool
proposal construction and evidence verification are gateway/orchestrator
work, not inferred by this coordinator.

Durable WAITING_APPROVAL excludes the wait from active accounting and holds
no sleeping worker. Reattachment is explicit and limited to a saved wait.
Active crash recovery refuses to invent a new monotonic anchor or replenish
budgets; SQD-028 must reconcile that case. These checks do not implement a
complete recovery workflow or authorize effects after an approval decision.

The unit suite has 19 cases. The SQL suite uses a fresh client after closing
the first pool, checks preserved loop/approval checkpoints and actor scope,
then holds a row lock and observes two real SQL transitions blocked behind
it before allowing a single winner. It verifies terminal immutability and
corrupt-checkpoint rejection. Small adapter queries atomically check/enqueue
on the NIO event loop: cancellation must not enqueue rollback or another
query on a closed channel with an unresumed promise. The same guarded path
is used by readiness. The issue command reports three groups; nested reports
record the 19 unit cases and one SQL scenario separately. CI runs unit policy
checks on macOS and the complete SQL integration on Linux.

## Tool catalog and strict schemas (SQD-006)

```bash
bash Scripts/test-issue.sh SQD-006
```

The standalone JSONSchema runtime is pinned to
[swift-json-schema 0.14.2](https://github.com/ajevans99/swift-json-schema/releases/tag/v0.14.2).
Its SwiftSyntax transitive revision is locked too; the application does not
use the macro/builder products. Existing dependency pins are preserved and
Domain gains no SDK dependency. Shared identity, SemVer, risk and definition
values live in Domain so policy and the gateway can share them without a
Tools/Security dependency cycle. This qualification covers the restricted
Squidra profile below, not complete JSON Schema standards conformance.

`ToolCatalog` is an immutable registry keyed by namespace, name and exact
SemVer; it never selects an implicit latest version. Definitions include
capability, R0–R4 risk, idempotency strategy, timeout and input/output byte
limits. Root input/output schemas use Draft 2020-12, an exact tool/version
URN and required string `schemaVersion:"1"`. Every object explicitly sets
`additionalProperties:false`. Unknown versions, keywords and formats fail
registration rather than silently weakening validation.

The profile supports typed objects/arrays/strings/numbers/integers/booleans/
null, required fields, enum/const, numeric bounds and bounded anyOf/oneOf/
allOf branches. Strings need maxLength, arrays maxItems and numeric types
minimum/maximum. Only uuid and date-time formats are supported and asserted.
All references, pattern evaluation and dynamic/unlisted features are rejected;
no schema reference triggers a network request. Catalogs have at most 256
definitions; schemas are at most 32 KiB, 256 nodes and depth 8, with at most
64 object properties or four branches per composition. Arrays allow at most
256 items; schema string limits allow at most 16,384 Unicode code points.

Payload scanning rejects duplicate decoded keys (including escaped aliases),
invalid UTF-8/JSON, depth over 32, more than 4,096 nodes, non-finite numbers
and number tokens longer than 128 bytes. Descriptor byte limits are capped
at 1 MiB. Validation and the adapter consume the same compact serialized
JSON tree. Its number tokens/order are preserved; these bytes are not claimed
to implement RFC-8785 canonicalization for semantic fingerprinting.

Qualification found that SDK 0.14.2 counts graphemes for string lengths.
The adapter translates those assertions to registered, checked-Sendable
string validators that count Unicode scalars and preserve the selected
format assertion. This happens inside the schema engine so composition
semantics remain correct. The committed tests cover combining characters
under both min/max length and oneOf, plus anyOf/allOf, enum, null and boolean
behavior. Original published schemas retain their standard minLength/
maxLength keywords; no third-party checkout is patched.

Execution requires a non-Codable grant whose initializer is internal to the
tools module. The future gateway must mint it only after policy, approval
and ledger checks. It binds actor/run, the full immutable definition, exact
validated arguments, scope, idempotency key and monotonic deadline. Changed
definitions/arguments are denied; R4 is always refused. There is currently
no production grant issuer or real tool registered. Calls are deadline-bound
and cooperative; validation alone does not provide sandboxing, durable
idempotency, approval or external-effect confirmation.

Output passes its schema before becoming an `UntrustedToolResult`. Unknown
instruction fields are rejected; schema-allowed instruction-like text stays
untrusted data and is never interpreted. Public errors use static codes and
messages without provider details. A timeout/invalid output/failure confirms
no result, including when an external effect might remain uncertain. The
sixteen tests run offline with fixture executors and cover zero invocation
for invalid input/denied grants, cancellation, timeout and error redaction.
No model calls, costs or real side effects are measured by this suite.

## Durable action ledger (SQD-007)

```bash
bash Scripts/test-issue.sh SQD-007-UNIT
bash Scripts/test-issue.sh SQD-007
```

The second command requires the existing isolated database image and a running
Docker/Podman engine. It runs the Swift adapter against real PostgreSQL, with
concurrent sessions held behind an observed database lock. One successful
`reserved → pending` compare-and-set grants dispatch; duplicates return a final
result, an in-progress record, or an explicit reconciliation requirement.
A reserved or pending record after a crash never grants another dispatch.
Final results and their minimal outbox notification commit in one transaction;
a forced outbox collision verifies that the result update rolls back as well.
The outbox is a durable notification queue; no external delivery worker is
implemented here.

Fingerprint profile `SQUIDRA-ACTION-1` hashes a UTF-8 prefix followed by a
canonical object containing actor UUID (lowercase), tool name and exact version,
target, arguments and sorted/deduplicated scope. It excludes the run UUID and
idempotency key, allowing the same logical command to replay from another run.
Object keys sort by UTF-8 bytes; arrays retain order; decoded strings retain
exact scalar content; decimal numbers normalize without a floating-point
round-trip (`1`, `1.0`, `1e0` agree; adjacent large integers remain distinct).
This is a frozen application profile, not an RFC 8785 implementation.
The bounded parser rejects duplicate keys, nonfinite numbers, NUL strings and
numbers whose expanded PostgreSQL JSONB text exceeds its 128-byte token limit.
Swift Crypto 5.0.3 supplies SHA-256; that exact version was already locked.

Results retain the validated catalog output's exact bytes and untrusted-data
classification. Finalization retries replay the stored result. A pending/unknown
outcome requires trusted provider or target evidence before reconciliation;
neither a model assertion nor absence of a receipt authorizes another effect.
Provider receipts remain internal. This does not promise external exactly-once
without provider support, perform approval checks, implement crash recovery, or
expose a business HTTP route. Those callers must use the host gateway and runtime
budgets before dispatch. No migration is added: the adapter uses T03's ledger,
run-scoped foreign keys, immutable commands, and outbox.
