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
the gateway must enforce. Timeouts and limit terminal reasons are
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
tools module. The gateway mints it only after policy, approval
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

## Action gateway and host policy (SQD-008)

```bash
bash Scripts/test-issue.sh SQD-008
```

`ActionGateway` is the sole production catalog dispatcher: execution grants and
`ToolCatalog.invoke` are internal to the Tools module. The composition root
registers each exact tool version, its bounded executor, and an explicit pure
resolver deriving its resource target from validated arguments. The supplied
target must agree, and the same target reaches policy, ledger and `ToolCall`.
There is no default resource resolver or registration for unrestricted shell,
SQL or HTTP. Adapter registrations and policies are trusted host code; a host
that deliberately misclassifies an unrestricted executor is outside this API's
trust boundary. Model/tool/client data cannot register adapters or permissions.

The default policy denies everything. `HostActionPolicy` permits only an exact
actor/tool/capability/target match with unexpired host permission and a nonempty
requested scope contained in that permission. Delegation may reduce this scope.
Policy exceptions become a static error. Authorization is bounded by the action
and tool deadlines, checked again immediately before adapter invocation, and
cannot waive R2–R4 approval. SQD-009 enables R2/R3 only through a verified durable
approval of the exact command. R4 extra controls remain unimplemented and cannot
be enabled by a caller boolean or an approval ID.

R1 and every non-read-only strategy require the ledger. Replays do not execute
again. Revocation after claiming but before execution persists a known
`notApplied` failure when storage is available. Provider failure, invalid output,
cancellation or timeout after dispatch remains unconfirmed: the ledger becomes
unknown when possible, otherwise pending, and duplicate submissions never retry
blindly. Successful mutation output is returned only after durable finalization.
Policy and adapters must cooperate with structured cancellation. This feature
adds no business HTTP route, provider integration, approval UI, recovery worker,
or global guarantee against arbitrary code executing outside the host boundary.

## Approval persistence (SQD-009)

```bash
bash Scripts/test-issue.sh SQD-009-UNIT
bash Scripts/test-issue.sh SQD-009-PERSISTENCE
```

The second suite requires the isolated PostgreSQL image. `ApprovalStore` persists
requests and one-way decisions without holding a worker while a human decides.
The host `ApprovalCoordinator` uses an injected Domain clock, authenticates the
approver through an identity policy (owner-only by default), and revalidates that
identity when issuing a non-Codable `VerifiedApproval`. Identity exceptions,
deadlines, cancellation, changed digests and cross-actor reads fail closed.
Future routes must supply the principal from their authenticated context.

Digest profile `SQUIDRA-APPROVAL-1` binds actor, run, ledger ID, the exact canonical
command fingerprint, and expiry in integer UTC epoch milliseconds. The command
fingerprint already covers tool/version/target/arguments/scope. Expiry is at most
600,000 milliseconds after the request, with an exclusive expiry boundary.
A repeated request returns the existing record without extending its TTL.
Only a reserved ledger entry can create a new request. Concurrent requests are
serialized by its row lock; decision changes lock the approval row. Equal final
decisions from the same principal replay, while opposite decisions conflict.
Final decisions are immutable; policy/identity revocation still blocks later
verification. A pending request resolved after expiry persists `expired`.

PostgreSQL supplies request timestamps and read-time observations; excessive
host/database clock skew prevents request creation. Resolution uses the later
host/database time, and proof verification also checks storage-observed time,
so moving the host clock backwards cannot hide database-observed expiry. The
adapter recomputes the persisted digest on every load and bounds each operation
to five seconds or less. No applied migration changes. Crypto 5.0.3 remains pinned.
The gateway, authenticated routes and runtime continuation below integrate this
port. No model-generated text constitutes an approval.


## Approval dispatch, API and continuation (SQD-009)

```bash
bash Scripts/test-issue.sh SQD-009
```

The host calls `ActionGateway.requestApproval` to reserve the exact command and
persist a request, without executing or holding a human-waiting task. Later it
supplies the returned approval ID to a fresh `GatewayAction`. R2/R3 and policy-
required lower-risk calls verify the approved record before claiming the reserved
ledger version. A guarded dispatcher rechecks policy, identity and expiry directly
before the adapter. Concurrent approved calls have one claim winner. Pending or
unknown records never grant a new permit; a failed pre-effect recheck records
`notApplied` where storage is available. R4 stays denied. Merely supplying an ID,
changing arguments/run/target/scope, or approving a different digest grants nothing.

The live server mounts authenticated routes:

- `GET /api/v1/approvals/:approval` returns a version-1 preview with tool/version,
  target, exact `argumentsJSON` text, scope, fingerprint, digest and UTC RFC 3339
  request/expiry times. Preserving arguments as text avoids preview rounding of
  large integers or decimals. Internal provider receipts/results are not exposed.
- `POST /api/v1/approvals/:approval/decision` accepts exactly three string members:
  `schemaVersion: "1"`, `decision: "approved" | "denied" | "withdrawn"`, and the
  displayed 64-character lowercase hex `digest`. This closed JSON grammar rejects
  duplicate/escaped keys, extra fields, identities, timestamps, non-string values
  and bodies over 1,024 bytes. Content-Type must be application/json.

Actor and approver come exclusively from the authenticated boundary. Unknown or
cross-actor approvals return 404; digest/opposite-decision/expiry conflicts return
409. Repeated equal decisions preserve their version. An expired approved replay
cannot authorize execution. The route persists a decision only; it does not run a
tool or automatically start a continuation. HTTP errors retain the boundary's
sanitized envelope, no-store, host request ID and origin checks.

`ApprovalWait.suspend` verifies the request exists and binds the run's proposal
fingerprint before durably entering WAITING_APPROVAL. `resume` loads that request
and restores only a waiting run. Pending returns immediately; approved returns a
controller in VALIDATING with its active budget intact; denied, withdrawn or
expired fails without tool calls. It never mints a tool grant or bypasses budget
accounting. A host/orchestrator must schedule continuation and then revalidate
policy/budgets through the gateway. Automatic recovery of active crashed runs
remains SQD-028. Tests cover controller restart with fixture stores; the separate
SQL suites qualify durable run and approval reload/CAS on real PostgreSQL. No live
external communication or destructive provider is registered by this integration.

## Shared bounded JSON documents

```bash
bash Scripts/test-issue.sh SQD-016-JSON
```

Domain's Foundation-only `JSONDocument` validates one complete UTF-8 document
and retains its exact bytes. The profile bounds documents to at most 1 MiB,
containers to depth 32, nodes (including object keys) to 4,096, and numeric tokens
to 128 bytes within the existing finite-Double interoperability envelope. It
checks JSON grammar, escapes and Unicode, rejects trailing tokens and decoded
duplicate keys (including Swift canonical-equivalent key aliases), and reports
NUL presence for stores such as PostgreSQL JSONB that cannot accept it. This is
not schema validation or canonicalization; large integers/decimal text are not
converted into new serialized numbers. Tools now applies this shared boundary
before its pinned SDK parser/schema evaluator. Domain imports no JSONSchema,
HTTP or database SDK. Catalog, fingerprint and approval regressions qualify the
shared change independently of the upcoming journal adapter.

## Append-only world journal (SQD-016)

```bash
bash Scripts/test-issue.sh SQD-016-UNIT
bash Scripts/test-issue.sh SQD-016
```

`WorldRepository.append` requires actor/stream, expected stream version (zero for
an empty stream), and a separate journal idempotency key. Equal keys and semantic
content replay the original event/correlation IDs, even if a retry supplies fresh
IDs or an old expected version. Content covers entities, type, source, confidence,
payload/version, occurrence/observation times, IANA zone and causation. Changed
content conflicts. New keys must match the current version; entity and causation
references remain actor-scoped. The ledger's keys/results are independent.

All qualified append transactions for one actor hold an advisory lock through
commit before allocating a sequence. This preserves commit order across that
actor's streams: a later append cannot become visible ahead of an earlier one
blocked on an entity reference. Snapshot pages capture one actor's high-water
sequence, keep it fixed across cursors and exclude later appends. Pages are
bounded to 128 events. A fresh query can tail after the previous high-water value;
global sequence gaps from other actors or rollbacks are valid. Raw SQL writers
that bypass the append port do not receive this ordering guarantee.

Journal times explicitly store microseconds (UTCInstant input rounds to that
precision). Unknown occurrence remains unknown. Recorded time comes from the
server; source time zone is preserved in a version-1 internal JSONB envelope with
the event payload. Input and normalized stored payloads must fit the shared JSON
profile and 64 KiB bound. JSONB expansion outside those bounds rejects before
insertion. Legacy rows lacking the envelope return unsupported-event instead of
inventing a time zone. No migration or existing journal UPDATE is introduced.

WorldProjector exposes idempotent application and versioned checkpoints. The
versioned `journal.v1.json` fixture uses a label projector to qualify correction,
per-stream gaps, unsupported versions, conflicting duplicates, paginated replay
and deterministic rebuild. Its frozen SHA-256 is
`42e666f184c2b35cbef156905baa6dab9633f41c745cc82bbb60086c6abb6324`.
The real SQL suite obtains that same hash after storage/reload and checks both
concurrent CAS and the blocked-first-append pagination case. The fixture is not
a spatial production projector: bitemporal facts/queries follow in SQD-014/015.
Operation deadlines remain bounded to five seconds or less; unknown errors expose
static codes. No journal HTTP endpoint, provider call or production data change.

## Bitemporal location facts (SQD-014)

```bash
bash Scripts/test-issue.sh SQD-014-UNIT
bash Scripts/test-issue.sh SQD-014
```

`LocationFactChange` defines a closed version-1 internal journal profile for
`world.location_asserted` and `world.location_corrected`. It binds subject,
location, actor-owned coordinate frame, an explicit positive half-open valid
interval, observed/inferred basis, and an optional corrected event. Its numeric
microsecond fields are internal storage, not public HTTP time DTOs. A correction
must causally reference the corrected event and declare both old/new locations
among its journal entities. Other relation/geometry semantics are separate work.

`PostgresLocationProjection` reads the authoritative stored event, verifies actor
and next actor sequence, and applies facts/checkpoint in one transaction. Equal
replay does nothing. Unrelated event types advance the location checkpoint;
unknown location versions/types fail. Assertions coexist. Correction closes only
the prior fact's transaction interval and inserts its replacement, preserving the
old valid interval for historical knowledge queries. It never updates the journal
or chooses one contradictory source as truth. A non-increasing recording time
cannot form a valid correction interval and fails without advancing the checkpoint.
Checkpoint JSON describes durable SQL metadata; it is not a complete row backup.

`WorldStateQuery.state(actorID:subjectID:validAt:knownAt:)` is the read-only SRS
`stateAt` alias. A repeatable-read snapshot applies both half-open dimensions.
Results retain valid/transaction intervals, source event/ID, confidence, basis,
IANA zone, and separate occurred/observed/recorded times. Missing, inferred,
conflicting same-frame locations and an incomplete projection are explicit
uncertainty flags. Missing occurrence is not replaced. Frame-independent
locations are not automatically contradictions. The reader checks materialized
subject/location/frame/validity/confidence against its immutable source; a
mismatch fails instead of returning unsupported evidence. More than 128 matching
sources returns a result-limit error instead of a partial, apparently complete
answer. Actors and unknown entities remain scoped.

The real SQL suite qualifies three movements, a late correction at two knowledge
times, exact boundaries, a forced checkpoint-write rollback, idempotent reload,
contradictory/inferred observations, source-confidence corruption, a foreign
frame, backwards recording time, and 129 legitimate observations. No migration,
package upgrade, spatial transform, business HTTP tool or external provider is
added. Automatic scheduling/recovery and evidence rendering remain later tasks.

## Bounded location changes (SQD-015)

```bash
bash Scripts/test-issue.sh SQD-015-UNIT
bash Scripts/test-issue.sh SQD-015
```

`WorldChangesQuery` requires a finite positive half-open valid-time window and
an explicit independent knowledge time. Subject and location filters are
actor-scoped. Location matches either the current location or supporting prior
location; for a correction, prior means the replaced fact. Results distinguish
an initial/repeated observation, a supported location-state change and a late
correction. An unknown prior, inferred evidence, conflicting locations and a
projection behind its journal are explicit. These are source-backed state
changes, not proof of a physical trajectory. Each result carries current/prior
facts and their supporting event IDs.

Pages contain at most 128 changes, ordered by effective valid time and fact ID
so equal-time observations have a stable tie-breaker. A typed cursor binds actor,
window, knowledge time and filters, plus the captured projected/available journal
watermarks. Later appends are excluded. When a correction was recorded before
knownAt but projected after capture, its immutable correcting-event sequence
lets the reader retain the old transaction visibility for the captured prefix.
A fresh query sees the correction; continuing the old query neither loses the
replaced fact nor changes its prior evidence. Missing closing provenance fails
instead of guessing. SQL uses fixed private fragments and typed parameter
bindings; no query value is interpolated as SQL grammar.

The reader uses a repeatable-read snapshot per page, bounded deadlines, and at
most 128 supporting predecessors per result. Excess support fails instead of
truncating. Changed filters, foreign/future cursors and unknown scoped entities
reject. An empty interval is invalid; an empty result means no matching recorded
change in that snapshot, not proof an object never moved. No HTTP/business tool,
geometry inference, package upgrade, migration or provider is introduced here.
The SQL suite qualifies exact endpoints, origin/destination/replaced-location
filters, equal-time paging, late projection catch-up, new appends, inferred/
conflicting evidence and the 129-predecessor failure case.

## Grounded response evidence (SQD-019)

```bash
bash Scripts/test-issue.sh SQD-019
```

Cognition consumes scoped world read values without depending on a database or
provider SDK. `AnswerEvidenceContext` validates actor/subject/time/filter scope,
retains up to 256 unique supporting events without truncation, and exposes a
version-1 evidence DTO with source, confidence, observed/inferred basis, distinct
occurred/observed/recorded times, IANA zone and observation age. Public times use
UTC RFC 3339 with six fractional digits. An unknown occurrence stays absent;
a future observation has clock-skew freshness and unknown age, never age zero.

Freshness policy requires an explicit maximum age and current-confidence floor.
Ages refresh from the injected clock at validation, after model generation.
Current-query evidence must still be within its known valid/transaction intervals,
with recent query/knowledge times, complete projection, sufficient confidence and
explicit permission for inferred current evidence. Old observations may support
historical/latest-observation answers with their stale flag; they cannot become
current evidence simply because ingestion or model generation happened recently.

The model may return only a bounded closed version-1 JSON object with `claims`.
Location claims select subject/location/frame and supplied citations; change
claims select a supplied change ID and all its supporting event IDs; unknown
claims carry no invented place or citations. Request IDs bind the response.
Unknown/duplicate/foreign/mismatched citations, unsupported subjects/locations,
hidden same-frame contradictions, extra confidence/dates/certainty/free text and
malformed/duplicate-key JSON reject. Basis and minimum cited source confidence
are computed by the host. Changes preserve the reader's observation/change/
correction distinction; no correction is rendered as proven physical movement.

The host renders controlled text and includes the complete supplied evidence,
uncertainty and coverage status. `grounded` means source-supported, not certain.
Missing frames/changes, partial pages or projection lag cannot yield apparently
complete coverage; abstention/unknown remains possible. Current-query text still
describes recent observation evidence, without claiming continuous physical
position. Source labels remain opaque data and never become model instructions.
The deterministic suite qualifies observed/inferred/historical/change answers,
stale/future/expired evidence, delayed validation, contradictions, partial pages,
clock failure, citation injection and scoped limits. No model/provider call or
answer HTTP route is introduced here; orchestration follows T14.

Timestamp wire dates use `SquidraDomain.RFC3339`, shared by grounded evidence
and future world tools. This explicit [RFC 3339](https://www.rfc-editor.org/rfc/rfc3339)
profile accepts Gregorian years 0001–9999, known explicit offsets, uppercase or
lowercase T/Z and up to nine fractional digits. It rejects impossible dates,
leap seconds, unknown `-00:00` offsets and UTC conversions outside the supported
range. Offsets do not identify an IANA zone; preserve that zone separately.
Output is canonical UTC with six fractional digits, rounded to microseconds.
`UTCInstant` uses Double, so distant dates can have coarser precision; input
precision is not a promise of nanosecond storage. The formatter uses proleptic
Gregorian arithmetic rather than a calendar that normalizes invalid input.
Run `bash Scripts/test-issue.sh T13-TIME` for the codec qualification.

`WorldLocationTool` exposes `world.get_entity_location@1.0.0` as an explicitly
registered R0 read through `ActionGateway`. Its only injected port is
`WorldStateQuery`; production HTTP registration remains a separate integration.
Arguments contain schema version, entity UUID, valid time and knowledge time.
The gateway supplies actor identity, checks the entity target and requires an
exact host permission for capability `world.location.read` and the caller's
nonempty scope (the fixture uses `world:read`). No ledger is required for this
read-only operation. Dates normalize to journal microseconds before querying.

The closed output retains every returned fact, confidence, observed/inferred
basis, source event, source text as untrusted data, all three timestamps, IANA
zone, valid/transaction intervals and projection watermarks. Contradictions,
inference and projection lag remain explicit. Sequence values use decimal
strings to preserve Int64 precision. No-evidence and not-found are distinct;
foreign entities share not-found and its unavailable watermarks are null.
The tool rejects inconsistent results, duplicates or more than 32 facts without
truncation. Results must also fit 128 KiB and shared JSON structural limits.
Its schemas are embedded and checked against `Schemas/tools/world` by
`bash Scripts/test-issue.sh T13-LOCATION`. This suite exercises the real gateway
with controlled read-port fixtures; PostgreSQL qualification is the independent
SQD-014 integration suite. Change and watch tools remain tracked by T13.

`WorldChangesTool` adds `world.get_changes@1.0.0` over `WorldChangesQuerying`.
An entity filter resolves to its exact `entity:<uuid>` policy target; an actor-wide
read requires the explicit `world:changes` target and `world.changes.read`
capability. The gateway supplies the actor and reauthorizes every call. Inputs
use finite RFC 3339 window/knowledge times, optional subject/touched-location
filters, a page limit of 1–8 and optional continuation. Output contains source
facts once by ID, current/prior references for each change, corrections,
uncertainty, projection watermarks and the next continuation. Up to 32 unique
source facts must fit 128 KiB and structural JSON limits; excess fails without
truncation. Empty pages invent no observations or movements.

The versioned base64 continuation captures query digest, watermarks and exact
internal position. Its digest binds the actor and normalized query values but
is not a signature, secret or authorization grant. Changing the request invalidates
continuation reuse; the backend still rejects future watermarks against its
actual journal/projection state. The wrapper verifies page ordering, retained
watermarks, exact next position, source scope and supporting intervals. This
preserves the SQD-015 snapshot contract without claiming that a user-editable
cursor is tamper-proof. `T13-CHANGES` qualifies the real gateway with controlled
query fixtures; SQD-015 separately qualifies PostgreSQL pagination. No HTTP
route, production registration or durable watch tool is introduced here.

`bash Scripts/test-issue.sh T13-READS` qualifies both world read tools through
ActionGateway and a real isolated PostgreSQL journal/projection. Its scenario
uses a late correction to compare frozen continuation, fresh corrected reads
and historical knowledge, while asserting retained source references,
confidence, IANA zone, unknown occurrence time and fractional timestamp
normalization. It also verifies explicit no-evidence/not-found results and
policy denial. The helper uses an ephemeral loopback-only container, temporary
credentials outside command arguments and existing migration/cleanup guards.
Linux CI runs it; macOS runs the deterministic tool suites. This is read-path
composition evidence, not provider, HTTP orchestration or watch qualification.

`ReadPlanner` prepares a single world-read proposal through `ModelRouter` for
T14. Host context is limited to 32 unique visible entities, labels of at most
128 UTF-8 bytes, a 4 KiB question, an explicit global-read proposal gate and a
finite maximum change window (up to 366 days). The clock supplies the reference
instant and IANA zone. Model selection, cloud consent, fallback, cost, output
and deadline bounds remain host-owned and enforced by the router.

A closed model envelope may contain only schemaVersion, exact tool identifier
and arguments. Only the two supported world read definitions are accepted;
the catalog and strict timestamp/visibility/window checks run before returning
an immutable non-Codable proposal. The model cannot supply cursor, actor, run,
scope, approval or policy. Untrusted labels/context and the question stay in
user-role messages, separate from fixed system rules. The proposal grants no
execution or factual certainty: the future RunEngine must charge durable
budgets, submit it to ActionGateway and validate a grounded response against
actual evidence. `T14-PLANNING` uses controlled LanguageModel fixtures through
the real router; no live model access or quality is claimed.

`WorldReadEvidenceDecoder` binds a registered read-tool result to its validated
ReadProposal and host actor before constructing AnswerEvidenceContext. It
revalidates schemas, query echoes, source records, intervals, source IDs,
watermarks, change references/order and uncertainty. Source text remains
untrusted data. Missing entities yield an explicit entityNotFound marker and an
empty context; they never invent a location. Opaque continuations are retained
for host-controlled paging and make the context partial even though no typed
backend cursor crosses the model boundary. The additional-pages flag can only
make existing grounded validation more conservative.

`T14-EVIDENCE` exercises actual world-tool results through ActionGateway and
then the grounded validator, plus deliberately corrupted host DTOs under
test-only visibility. Decoding verifies consistency and scope; the producer's
PostgreSQL source validation is qualified separately by T13-READS. It grants no
execution rights and is not a cryptographic source-authentication mechanism.

`ReadRunEngine` implements one durable, read-only iteration for T14: persisted
validation/context/planning states, a ModelRouter-validated ReadPlanner proposal,
host ActionCommand digest, persisted attempt reservation, ActionGateway read,
scoped evidence decoding, structured answer routing, grounded validation and
only then completion. It has no executor port, effectful tool, retry loop or
active-crash recovery shortcut. Host identity/scope, model consent/options,
freshness policy and tighter RunBudget values remain explicit inputs.

The caller deadline tightens the active budget. One absolute monotonic deadline
bounds planning, tool and answer waits; two model routes share a single
conservative cost-reservation ceiling. Provider/source text stays outside system
instructions. Partial or unknown answers remain explicit; invalid citations
cannot complete a run. HostVerifiedProgress.validatedResponse records a completed
grounding check, including a legitimate unknown, without claiming new evidence
or a confirmed effect. It is not persisted or supplied by model text. Existing
no-progress loop bookkeeping still applies to unvalidated iterations.

Cancellation uses owned, awaited cleanup with the existing bounded RunStore I/O
contract. Ambiguous checkpoint writes detach the controller and grant no further
dispatch; the engine reports recoveryRequired rather than inventing a terminal
state. The facade does not resume such a run. `T14-RUN` qualifies actual
planner/router/gateway/decoder/validator composition with controlled model,
read-port and store fixtures; its reported token/cost values are fixture data.
Real PostgreSQL run composition and HTTP integration require separate checks.

`bash Scripts/test-issue.sh T14-SQL` qualifies ReadRunEngine with real
PostgresRunStore, journal and projections plus controlled ModelRouter fixture
responses. It reloads completed checkpoints through a separate PostgreSQL
client and compares them to returned snapshots. Historical and late-corrected
answers retain actual source event IDs, confidence, IANA zone, unknown occurrence
and explicit staleness. A missing-evidence answer completes under one-step,
one-call and one-repetition limits; a one-page change answer remains partial.
An isolated trigger rejects the dispatch-reservation checkpoint and proves that
recoveryRequired grants no read and invents no terminal state. The helper cleans
up its temporary loopback database and credentials. This is database composition
qualification, not process-restart, HTTP or live-model qualification.

Semantic input rejection inside a bounded R0/readOnly adapter remains
TOOL_INVALID_INPUT, allowing its HTTP adapter to report a static client error
for actor-bound cursor validation. Effectful or ledger-backed adapter failures
remain normalized as providerFailure; an unconfirmed effect cannot be recast
as a harmless input error. The existing SQD-006 suite verifies all combinations.

The authenticated local-owner HTTP API exposes `POST /api/v1/world/location`
and `POST /api/v1/world/changes` using the exact tool input/output schemas in
`Schemas/tools/world`. Both require one application/json content type and the
injected bearer credential; the existing approved-origin/actor-header boundary
applies. Actor identity and fresh request IDs come from the host. Body fields
cannot supply identity, scope, tool selection or permission. The host creates
an exact validated entity/global-read permission with fixed world:read scope;
live PostgreSQL ports remain bound to that actor.

The endpoints return schema-validated factual evidence and uncertainty with
no-store headers. They do not generate natural-language answers or mutate the
world. Invalid dates, malformed/foreign continuations and authoritative future
watermark rejection return static 400 errors; oversized route bodies return
413. Missing entity state remains an explicit not_found DTO, while backend
failure/corruption is redacted. Generic schema timestamps are further checked
against the strict Squidra RFC 3339 profile before target authorization.
`T13-HTTP` covers real router and live HTTP requests. T13-READS qualifies actual
PostgreSQL cursor rejection; T04, SQD-009 and SQD-001 regress boundary,
approval and real process/signal lifecycle behavior.

`WorldProjectionRecovery` replays a frozen actor journal snapshot from the last
valid location-projection checkpoint. Defaults are pages of 64, at most 10,000
visited events and 30 seconds; callers may tighten or explicitly configure the
bounded limits. It validates version, actor, event identity/order, cursor,
watermark and checkpoint progress. A committed prefix survives a failed replay
and can resume; no success report is returned for an incomplete snapshot.
A concurrent later append is outside the captured snapshot and remains explicit
projection lag in subsequent reads.

Live composition runs recovery through Hummingbird's beforeServerStarts hook:
the owned database client runs, but HTTP cannot precede replay. Unsupported,
corrupt or over-limit recovery fails startup with the existing static error.
An empty projection cache can rebuild entirely from the immutable journal;
a missing checkpoint with orphaned rows fails instead of overwriting data.
Arbitrary cache-corruption repair is not claimed. Recovery itself deletes
neither cache nor source data.

`SQD-025-RECOVERY` runs bounded/cancellation contract tests and real PostgreSQL
resume, empty-cache rebuild, stable current/historical facts, provenance,
actor isolation, event-limit prefix/resume and invalid-cache checks. Test-only
cache removal is scoped to the isolated actor. Two actual application-process
restarts and HTTP response equivalence are qualified separately by SQD-025.

`bash Scripts/test-issue.sh SQD-025` proves persistence with two actual
`squidra serve` processes against one isolated migrated PostgreSQL database.
Separate nonempty Swift seed/reset/verify suites write an immutable movement
and correction, retain an unrelated actor, remove only the primary actor's
mutable cache between processes and verify the rebuilt database afterwards.
The first server starts from an empty projection; the second must rebuild again.

The driver compares four canonical HTTP bodies: corrected location, historical
knowledge, full change evidence and explicit no-evidence state. It independently
checks actual source IDs, original timestamps, confidence, zone, watermarks and
correction references, and rejects missing/altered counterexamples. Transport
request IDs must be fresh and remain outside semantic comparison. SIGTERM and
SIGINT both stop their owned process cleanly. Credentials stay in environment
or private temporary files; both children and the loopback database are cleaned
up on failure. The run prints its actual canonical evidence digest, not a fixed
cross-run golden value (fixture UUIDs are freshly generated). No model/provider
or production-data reset is involved.
