# Private run tracing

`PrivateTraceRecorder` uses actual OpenTelemetry SDK spans and a bounded
in-memory exporter. The live read host installs worker, model, tool and projection-query tracing.
Journal/projector decorators provide the corresponding ingestion hooks. No network
exporter is configured.

## Qualified dependency boundary

The pinned dependency is exact `opentelemetry-swift-core` 2.6.0, revision
`c6fcee77cfc21ba400366f12475217c7b6e1d605`, Apache-2.0. Its Swift 6 manifest's only
package dependency is swift-atomics >=1.3.1, already pinned in Squidra. SwiftNIO
is declared directly at its existing locked version to expose the existing
NIOConcurrencyHelpers product. The original SDK integration added only that repository pin; live-host wiring
changes no dependency versions or revisions.
Sources: [release](https://github.com/open-telemetry/opentelemetry-swift-core/releases/tag/2.6.0),
[immutable manifest](https://github.com/open-telemetry/opentelemetry-swift-core/blob/c6fcee77cfc21ba400366f12475217c7b6e1d605/Package.swift),
[license](https://github.com/open-telemetry/opentelemetry-swift-core/blob/c6fcee77cfc21ba400366f12475217c7b6e1d605/LICENSE).

Upstream has paused development in this standalone repository while integrating
it into the main OpenTelemetry Swift project. This is a frozen dependency behind
Squidra's typed facade; a future SDK migration requires separate qualification.
The package manifest emits an upstream deprecated watchOS deployment-target
warning with Swift 6.4.2. This does not qualify watchOS or imply a Squidra
application warning has been suppressed.

## Correlation and content controls

The host supplies a fresh UUID trace identifier, run identifier and optional task
identifier. The trace UUID maps exactly to the SDK's 128-bit trace ID. SDK span IDs
are random, nonzero 64-bit values. Task-local opaque handles connect children to
their explicit session; a nested or concurrent session keeps its own root.
Client tracing headers are not accepted by this facade and grant no authority.

Stages are a closed enum: run, context, planning, model, tool, journal, projection
and answer. Usage accepts bounded token/cost counters, positive journal sequence
numbers and UUID request/event/ledger references. These counters are supplied
measurements, not SDK measurement of model usage or an authorization budget.

No public operation accepts a dynamic span name, arbitrary attribute, prompt,
response, tool result, media, filesystem path, header or error description. Errors
propagate to the caller unchanged; spans receive only static failed/cancelled
outcomes. The final exporter also filters SDK data into an allowlisted snapshot,
excluding arbitrary keys, descriptions, events, links and resource content. The
resource is the static Squidra service name. Source IDs and object labels are not
trace attributes. UUID references and timing are still operational metadata, so
snapshots must stay inside the authenticated diagnostic boundary.

## Lifecycle and limits

The recorder actor owns providers, live spans and their dictionaries. A checked
Sendable exporter uses the existing NIOLockedValueBox for synchronous bounded
storage; no custom unchecked conformance or concurrency opt-out is introduced.
It registers no global provider, detects no environment resources and creates no
network exporter, dispatch backlog, background exporter task or telemetry file.

Default limits are 16 concurrent traces, 64 spans per trace, depth 8 and 4096
stored finished spans. Configuration has fixed upper bounds. Excess work runs
normally with explicit dropped-span counts. A dropped span's descendants cannot
bypass the depth limit. Cancellation and thrown operations close their spans;
root cleanup also closes any remaining spans as scope_closed. An escaped session
cannot recreate a finished trace. Operations themselves remain responsible for
structured task ownership and cooperative cancellation.

`snapshot(clear:)` returns only ended, redacted SDK span records, active counts
and dropped counts. Clearing discards the finished diagnostic buffer and its
loss counters; it does not change active business operations. This inspection
DTO is not an OTLP wire format or a durable trace store. No remote telemetry
endpoint has been qualified.

## Verification and remaining integration

Run `bash Scripts/test-issue.sh SQD-030-UNIT`. The suite inspects actual SDK span
export and parent IDs, host correlation, concurrent/nested isolation, original
error propagation with secret canaries absent from snapshots, cancellation,
usage references, bounded capacity/depth and defensive exporter redaction.
Hosted Linux/macOS qualification will be rerun after the explicitly authorized CI suspension.

The live-worker qualification below covers model/tool/event correlation, host
HTTP IDs and durable run integration. A future
exporter must preserve the same content restrictions and require explicit host
configuration. Disabling host tracing requires removing the explicit decorators and executor
wrapper; it must preserve the underlying gateway and runtime behavior. No database
migration is required.

## Opt-in port decorators

`TracedLanguageModel`, `TracedToolExecutor`, `TracedWorldRepository` and
`TracedWorldProjector` use the current task-local private session when present.
They are explicit composition choices; the live read host installs the model and
tool wrappers. Journal/projector wrappers remain available to ingestion hosts.
Every underlying operation executes once with its original values, error and
cancellation semantics. Calls without a session remain unrecorded. Nested and
concurrent sessions restore their own context; no SDK global context is used.

A tool's granted run ID must match the session's host run ID to be recorded.
A mismatch delegates normally and increments the dropped-span counter, avoiding
false run attribution. Neither tracing context nor a decorator can create a tool
grant or bypass gateway policy, catalog validation, approvals or the ledger.

Provider/executor success means that the physical port returned. ModelRouter or
the tool catalog can still reject that returned value. Host request IDs identify each attempt. Bounded provider-reported usage is
recorded after response identity checks; those values are not measured spend
or a validated business result. Confirmed journal
appends record their event UUID and sequence; page spans record their snapshot
watermark, and projection spans record applied event/checkpoint references.
Prompts, model/tool identity strings, targets, idempotency keys, source labels,
raw output, payloads and exception descriptions remain excluded.

Run `bash Scripts/test-issue.sh SQD-030-PORTS` for actual ModelRouter/ActionGateway
composition and controlled journal/projection qualification. The live HTTP qualification below completes worker/server correlation.

## PostgreSQL source qualification

`GatewayToolRegistration.decoratingExecutor` wraps an executor while preserving
its complete definition, bounded surface and original private target resolver.
Composition can add a tracer without duplicating target-binding logic. This is
a trusted construction hook and grants no authority.

`bash Scripts/test-issue.sh SQD-030-SQL` uses a disposable loopback PostgreSQL
instance, real journal/projection adapters, actual ModelRouter fixture attempts
and the actual world-location ActionGateway registration with a traced executor.
The returned source event UUID is checked against ended journal/projection SDK
spans under one host trace/run/task correlation. Source labels and output remain
present in the actor's evidence response and absent from the trace snapshot.
Negative cases verify that foreign actors, mismatched targets, unknown input
properties and denied policy cause no SQL query dispatch after decoration.
This qualifies component composition; the separate live test below verifies
HTTP/run activation. Neither test measures actual provider quality.

## Live worker and authenticated retrieval

ServerComposition creates a bounded process-local recorder by default, or accepts
an explicitly supplied private recorder for host diagnostics. The owned read
worker opens the root using the server-generated traceId/runId; taskId is the
host request UUID for this single-task run. It records requestId on the root and
attempt IDs on model spans. Closing the submitting HTTP connection does not own
or close this trace. The root describes executor completion, not successful
publication or network delivery; persisted run status remains authoritative.

TracedWorldQueries records actual projection-query spans and committed watermarks.
After answer grounding succeeds, answer reference spans record only cited source
event UUIDs. They are reference spans, not invented journal-read operations. Model
and tool decorators preserve original target resolution and permission checks.
No model names, questions, labels, arguments, raw SQL, output text or errors are
added to the export. A read run need not append a new journal event; its trace
links back to the immutable events used by its answer.

Authenticated `GET /api/v1/runs/:run/trace` first verifies actor-scoped durable
run ownership and retention. It returns at most 256 redacted ended SDK spans for
that run, schemaVersion 1 and retention `bounded_process_memory`. Anonymous,
foreign and absent-run requests retain their normal boundary errors. Replay and
trace reads do not execute models or tools. Traces disappear on process restart
or bounded-buffer eviction. `partial` is true if no ended root is retained, any
recorder drops have occurred, or the response was capped. The dropped-span flag
is deliberately conservative across the recorder; it never asserts completeness
after a known drop. Retrieval never clears other runs' spans.

Run `bash Scripts/test-issue.sh SQD-030` for the complete acceptance gate: private
SDK isolation/redaction, model/tool/journal/projection port correlation, actual
PostgreSQL source identity, and live worker/HTTP retrieval. The live test checks
host trace/run/task IDs, actual SDK root/model/tool/projection spans, cited event
identity, auth/isolation and absent secret/prompt/source canaries. Cancellation
ends root and child spans without evidence or leaked text. All export is in
memory; no mandatory telemetry endpoint or network transmission is introduced.
