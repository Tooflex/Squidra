# ADR-009: Bounded AG-UI producer and resumable run transport

- Status: Initial protocol profile accepted by the authorized merge of [PR #134](https://github.com/Tooflex/Squidra/pull/134). Later implementation sections follow their own linked PR qualification.
- Date: 2026-10-31
- Sources: T05 / SRS §3,8; ADR-001/002/007/008; official AG-UI 1.0.

## Frozen upstream artifact

Use AG-UI protocol **1.0**, from upstream release `release/2026-10-30`, commit
`1a9b3db4ea5145f263c66049e836c8896df66269`. This protocol version is independent
of JavaScript SDK package versions. The canonical schema was fetched and matched
the immutable release file: 94,359 bytes, SHA-256
`4b5c93226838a0e72d88e6c5df20633c686c49fcb75d9be2815c6cbf9e48e71a`.

Keep the exact schema and upstream MIT license under `Schemas/protocols`.
Selected official fixture documents retain their original UTF-8 bytes, source
paths, URLs and hashes inside `fixtures/protocols/agui.1.0-selected.json`.
They are official conformance inputs. Squidra-generated events remain separately
identified test output.
Sources: [immutable schema](https://github.com/ag-ui-protocol/ag-ui/blob/1a9b3db4ea5145f263c66049e836c8896df66269/spec/1.0/schema.json),
[official fixture tree](https://github.com/ag-ui-protocol/ag-ui/tree/1a9b3db4ea5145f263c66049e836c8896df66269/spec/1.0/fixtures),
[stream fixtures](https://github.com/ag-ui-protocol/ag-ui/tree/1a9b3db4ea5145f263c66049e836c8896df66269/spec/1.0/conformance/streams).

## Squidra producer profile

Produce run start, success/cancelled completion, static redacted run errors,
assistant text start/content/end, and the named CUSTOM event
`squidra.grounded_answer.v1`. RUN_STARTED declares protocolVersion 1.0. The
profile omits rawEvent, echoed input, reasoning, arbitrary custom payloads and
provider-native output. No general-purpose AG-UI consumer is claimed.

Only a GroundedAnswer already produced by GroundedAnswerValidator can enter
the answer factory. Actor and request IDs must match the host run binding.
Create the evidence extension and complete text-message triad before publishing
any of them. This delivers validated answer text after grounding; it does not
publish unvalidated model token deltas. The named extension carries the existing
versioned grounded answer, including uncertainty and provenance, to the actor's
UI. It grants no authority.

The official schema allows empty text deltas; the profile validator accepts them.
It accepts a missing start protocolVersion as a legacy stream, rejects a present
unsupported version, and enforces the narrower supported field/event profile.
Run errors carry only official message/code fields plus the base timestamp;
run/thread identity remains in the host-bound stream record rather than adding
undeclared RunError properties. Cancellation uses RUN_FINISHED with the official
cancelled outcome.

Each event is at most 65,536 UTF-8 bytes. A run has at most 128 events; the last
slot is reserved for a terminal event. One assistant message is supported, with
contiguous sequence numbers and matching start/content/end IDs. Reject gaps,
repeated starts, cross-run IDs, open-message completion, events after termination,
unknown profile fields, explicit null optional fields and unsupported versions.
Validation failure leaves its previous state intact. The structural stream
validator does not reconstruct a GroundedAnswer proof from stored JSON.

AG-UI timestamps are host-created integer milliseconds. Evidence keeps its own
original RFC 3339 observation/record/occurrence times and IANA zone. A timestamp
never supplies event ordering: the persisted run-local sequence does.

## SSE and planned API extension

SSE emits one compact JSON data line and a canonical base64url cursor in its id
field. CR/LF inside JSON text stay escaped; multiline storage bytes are rejected.
Keepalive comments carry no event ID and do not advance replay position.
Source: [HTML SSE parsing](https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream).

T05 plans POST /api/v1/runs returning 202, actor-scoped status reads and a separate
GET event stream. This is a Squidra transport extension. The standard AG-UI
HttpAgent POST-stream path is not automatically compatible; a client transport
adapter is required. AG-UI's default binding defines no Last-Event-ID resumption;
that behavior belongs to this extension. Native EventSource cannot supply Squidra's bearer header,
so the UI must use authenticated fetch streaming rather than put tokens in URLs.
Sources: [AG-UI HTTP SSE transport](https://github.com/ag-ui-protocol/ag-ui/blob/1a9b3db4ea5145f263c66049e836c8896df66269/docs/spec/1.0/basic/transports/http-sse.mdx),
[EventSource interface](https://html.spec.whatwg.org/multipage/server-sent-events.html#the-eventsource-interface).

Authorize actor/run ownership before consulting retention bounds. Cursors encode
actor, run and the last consumed sequence as exact strings; they are pagination
positions, not secrets or grants, and are not cryptographically signed. Reject
noncanonical, future and foreign-scope values. A cursor older than retained
history gives cursorOutsideRetention; the future HTTP adapter maps this to an
explicit expiration response (planned 410). A fresh read cannot silently begin
mid-history. Reconnect only replays persisted events and never dispatches an
action or starts another run.

The HTTP implementation must preserve the existing bearer/origin/body boundary
and bounded handler deadline. Last-Event-ID preflight support is qualified with
its route and tests below. A closed SSE connection alone does not mean a run
failed; a transport/replay error must not fabricate a RUN_ERROR terminal event.
Durable worker ownership, event retention, replay authorization, atomic status/
event publication and process-restart behavior require separate qualification.

## Qualification and limits

`bash Scripts/test-issue.sh T05-CONTRACTS` validates the pinned schema/license and
16 official event fixtures, six official stream outcomes, generated grounded
answer events, actor/request binding, sequence/version/null guards, static errors,
cancellation, precise/scoped/expired cursors, SSE injection resistance and limits.
Official fixture expectations are preserved; profile diagnostics use Squidra's
typed errors rather than copying SDK error descriptions.

The initial contract qualification adds no HTTP route or worker. Durable storage
is qualified separately below; T05 stays open for transport and execution
integration. No package version changes are needed. Reverting only the producer
contracts removes their tests and immutable qualification artifacts.

## Durable replay store (T05 persistence)

The actor-bound `PostgresRunEventStore` stores publication metadata independently
of the runtime FSM. This permits acceptance before worker creation without
conferring dispatch authority. Identical creation preserves its original expiry;
a changed binding or retention period conflicts. Atomic append requires the next
sequence and validates the complete stored chronology before publication.

Limits are 128 events and 1 MiB of canonical JSON per run, 64 KiB per event,
16 events / 256 KiB per append, 32 events per page and 1–604800 seconds retention.
Overflows fail without truncation or partial writes. Owned stream lookup precedes
cursor decoding; another actor cannot probe cursor validity. Reopening a client
replays the same persisted SSE frames and never calls a model, tool or worker.
Malformed chronology, missing rows or inconsistent counters fail closed.

Expiry is logical: expired streams cannot be read, appended or revived. Physical
purging, backup retention and restore remain T12 work. Event UPDATE is forbidden;
DELETE is reserved for future authorized retention maintenance, and any premature
hole invalidates replay. Partial history pruning is not yet supported.

`bash Scripts/test-issue.sh T05-SQL` qualifies two-client replay, ownership,
creation/append conflicts, concurrent CAS, transactional database-error rollback,
immutable events, corruption, byte/event/batch limits, expiry and cancellation.
Migration `runtime/002_run_events.sql` is forward-only. Deploy its matching schema
manifest and binary together: reverting only the binary fails schema readiness.
No HTTP endpoint, worker ownership or atomic runtime/result publication is added
by this persistence change; T05 remains open for those integrations.

## Single-owner publication (T05 ownership)

`RunPublicationStore` is a publication boundary, not an execution/approval permit.
A host first creates a stream, then obtains one fresh successful claim before
starting its bounded worker. Claiming an intact empty unmanaged stream fixes an
opaque backend owner and atomically publishes RUN_STARTED. Any second claim,
including one after an ambiguous response, conflicts. Do not dispatch on an
ambiguous claim error; inspect status and let abandoned ownership expire.

Execution is bounded to 1–180 seconds. A five-second publication grace is added
to the database-clock lease; the returned execution deadline excludes this grace.
The host must enforce its worker deadline and join cancellation before publishing
cancelled completion. Leases cannot be renewed or transferred. Retention must
outlast the lease. Database wall-clock adjustments can affect when recovery is
eligible, but they never authorize another execution. Reconnection has no claim,
model or tool-dispatch path.

Only the backend's opaque claim can publish a managed terminal outcome. A whole
GroundedAnswer produces its four presentation events plus RUN_FINISHED atomically
with `succeeded`; a static failure or cancelled finish commits with its matching
phase. Status never exposes the owner nonce. Generic event append cannot write a
managed stream. Lease/retention are checked again before the metadata update;
failed publication rolls back both event rows and phase. An uncertain completion
must be resolved through persisted status/replay, never by rerunning the model.

An owner-scoped maintenance call may terminalize an expired running lease with
static RUN_RECOVERY_REQUIRED. It never restores an active runtime or repeats any
read/action. A late completion conflicts, and retention expiry still prevents
revival. Recovery is explicit per run; automatic scanning, worker composition,
HTTP status/cancellation and restart orchestration are separate work. A crash
after the runtime completed but before its answer was durably published still
requires recovery; this layer cannot reconstruct a GroundedAnswer proof or claim
successful output from the runtime checkpoint alone.

Migration `runtime/003_run_publication.sql` adds ownership and constrained phases.
Existing streams remain `unmanaged`, including previously terminal streams; they
are not silently labeled successful. It requires the matching schema manifest
and binary. `bash Scripts/test-issue.sh T05-PUBLICATION` qualifies concurrent
claims, opaque/foreign ownership, generic-append isolation, terminal SQL rollback,
reopened status/replay, expiry recovery and late-completion rejection. Physical
retention/backup cleanup remains T12.

## Owned read workers (T05 coordinator)

`PublishedReadRunCoordinator` reserves capacity before its first await, binds the
host actor/request/run/thread, and requires a fresh matching durable claim before
execution. Default capacity is four (configurable 1–8); retained stream lifetime
is host-configured, 186–604800 seconds (default 3600). Questions are bounded to
4096 UTF-8 bytes and effective scope is exactly `world:read`. An uncertain or
misbound claim never dispatches; no ownership is reconstructed from status.

The narrow `ReadRunAnswerExecuting` port returns only a GroundedAnswer. Its
production implementation delegates to the existing bounded ReadRunEngine.
Implementations must cooperate with cancellation and deadlines. The coordinator
also applies a monotonic timeout, clips the wall deadline to the claim's execution
deadline, caps active time at 180 seconds and preserves the original smaller
budget/cost/privacy settings. Actor/request/intent and permitted-subject proof binding are checked again before
publication. Static errors expose no prompt, exception text or raw model output.

Accepted workers have host-owned tasks, independent of the caller/HTTP connection.
A completed or failed worker performs cancellation-resistant final publication in
an owned task and awaits it. Publication uncertainty is resolved through persisted
status/replay or lease-expiry recovery, never another model/tool execution. A
worker failure cannot overwrite an already committed terminal outcome.

Shutdown closes admission, cancels active workers, and joins their cooperative
execution/publication cleanup plus submissions still awaiting claims. The host
must await shutdown before tearing down database/client services. There is no
fire-and-forget cleanup or automatic active-run restart. Capacity is released on
all submission/worker exits; unavailable publication may leave the durable lease
requiring explicit recovery. No raw question is persisted by this coordinator.

`bash Scripts/test-issue.sh T05-WORKERS` uses real PostgreSQL publication/event
stores and controlled cooperative executor fixtures. It covers transport/caller
cancellation after acceptance, capacity, duplicate submission, replay/status
without another execution, uncertain terminal response, ambiguous/misbound claims,
shutdown racing a claim, deadlines/cancellation and foreign actor/subject/intent proof rejection.
These are lifecycle fixtures, not live model-quality tests; existing T14-RUN and
T14-SQL qualify the underlying model/gateway read engine separately.

This adds no HTTP route, provider activation, automatic recovery scanner or
application lifecycle wiring. The future host composition must own a run trace
for the worker's full lifetime; inheriting an already closed HTTP trace scope
does not qualify end-to-end tracing. T05 and SQD-030 remain open for that work.

## Authenticated HTTP transport (T05 HTTP)

The custom version-1 transport exposes:

- `POST /api/v1/runs`: with host-configured submission, accept the closed JSON
  object `schemaVersion` (string `"1"`), `question`, `entityId` and `intent`
  (`historical`, `latest_observation`, `current`). The decoded question is at most
  4096 UTF-8 bytes; the body is at most 32768 bytes, including JSON escapes. Reject
  duplicate/unknown fields, nulls, invalid types and unpermitted entity IDs.
  Identity, effective scope, model/consent/cost settings and fresh run/thread/
  request/trace IDs come from the authenticated host. Return 202 only after a
  durable claim and worker registration, with relative status/events links.
- `GET /api/v1/runs/:run`: return actor-owned publication phase, terminal/output-
  ready flags, retention/sequence metadata and optional runtime diagnostics. The
  runtime checkpoint's frozen state names are preserved. Runtime `Completed`
  alone is not output completion: only publication `succeeded` makes
  `outputReady` true. Never return questions, owner nonces or raw errors.
- `GET /api/v1/runs/:run/events`: return one finite bounded SSE batch (at most
  32 retained events, 1100000 encoded bytes), with existing canonical event IDs.
  Authenticated clients reconnect using `Last-Event-ID`; it is not an auth grant.
  Perform owned lookup before cursor validation. Empty nonterminal reads may
  long-poll for at most 20 seconds, then return a heartbeat comment with no ID.
  Bound all handler I/O to 25 seconds within the default 30-second HTTP boundary.
  Bodies are already bounded/materialized when headers are returned; there is no
  unbounded body-writer task. Socket delivery still uses the server's normal
  transport backpressure/idle lifecycle, not a claimed absolute transfer SLA.

This is finite GET-SSE replay/long polling with POST-202 acceptance, not a drop-in
AG-UI HttpAgent POST-SSE adapter. Native EventSource cannot supply the required
bearer header; a client needs authenticated fetch/stream parsing and reconnection.
Advance the cursor only after processing an event. A fresh view can read from the
start; a consumer must not discard its presentation state while keeping a cursor
past the grounded-answer event. GET/status/reconnection and transport failures
never dispatch, resume, cancel or fabricate a business RUN_ERROR.

Malformed/future/foreign cursors return 400; unknown owned-scope IDs return 404;
expired retention returns 410/EXPIRED. Corrupt/unavailable storage fails closed.
Private errors retain the fixed filtered envelope and fresh host request ID;
503 now has UNAVAILABLE, and 410 has EXPIRED. Add Last-Event-ID only to the existing
single-approved-origin preflight allowlist; no cookies, wildcard origin or URL
credential is introduced. All responses retain no-store.

Default live composition exposes authenticated read-only persisted status/replay.
POST remains 503/UNAVAILABLE until a host supplies its permitted entities and a
bounded read coordinator; this change activates no model/provider or fixture
fallback. The worker service is registered after the database client. Hummingbird
appends its HTTP service last; ServiceLifecycle gracefully stops them in reverse
order, so HTTP admission stops, worker cleanup/publication is joined, then the
client stops. The explicit ServiceLifecycle root declaration uses the already
locked 2.13.0; no package version or lockfile change is needed.

`bash Scripts/test-issue.sh T05-HTTP` qualifies real PostgreSQL transport with
controlled local model responses through ReadRunEngine/ModelRouter/gateway/world
projection, plus independent cooperative lifecycle fixtures. Checks include fresh
identity and scoped input, grounded provenance/unknown occurrence, exact SSE
ordering/resume, cursor/retention errors, no extra model/read on reconnect,
preflight, actual loopback client cancellation and joined shutdown with an active
worker. These fixtures do not measure live model quality, tokens or cloud cost.
There is no new migration, raw prompt persistence or automatic restart/recovery.
Parent T05 still needs host/provider activation, worker-owned tracing and wider
process-restart qualification.

## Explicit cancellation

`POST /api/v1/runs/:run/cancel` requires the same bearer/origin/actor boundary,
no query parameters and an empty body. It performs an actor-owned durable lookup
before signalling the local coordinator. A 202 acknowledges a cancellation
request, not completed cancellation; its body is a fresh `RunHTTPStatus`. Poll
status or replay events to observe durable completion. A terminal run returns
200 with its existing outcome, including a success that won the completion race.
An active run without a local owner returns 409 and requires recovery. The route
cannot manufacture a cancellation or restart a worker. Unknown/expired IDs retain
404/410. A missing configured coordinator returns 503 for active runs.

A withdrawn durable approval is observed by `ApprovalWait.resume` as terminal
CANCELLED, without approving or dispatching its action. Denial and expiry remain
policy failures. This is a separate continuation path from the read-only HTTP
coordinator; the cancel endpoint does not claim to execute arbitrary mutations or
withdraw approvals. Mutations require independent effect-ledger reconciliation.

Local T05-HTTP covers explicit cancellation, authentication and actor rejection,
closed inputs, terminal repeats, late cancellation preserving success and orphan
ownership conflicts. SQD-009 covers persisted withdrawal cancellation and refusal
to resume a terminal waiter. Hosted cross-platform qualification remains pending
until the authorized CI suspension ends.

Interrupted mutating gateway calls join a separate, bounded four-second ledger
cleanup. If dispatch began, the effect becomes `unknown`; otherwise it is confirmed
`notApplied`. The cleanup survives caller cancellation and attempt expiry. Failed
cleanup reports `outcomeUnconfirmed`; neither case claims success or rollback.
A subsequent identical command returns reconciliation-required instead of
re-executing an unknown effect. Only independent provider/target confirmation may
resolve it through the existing ledger reconciliation port. SQD-008 tests both
cancellation and deadline expiry with a cancellation-aware ledger fixture.
