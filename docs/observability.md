# Private tracing foundation

`PrivateTraceRecorder` uses actual OpenTelemetry SDK spans and a bounded
in-memory exporter. It is an isolated library foundation; run, model, gateway,
journal, projection and HTTP integration are still tracked under SQD-030. No
server composition enables tracing automatically in this change.

## Qualified dependency boundary

The new dependency is exact `opentelemetry-swift-core` 2.6.0, revision
`c6fcee77cfc21ba400366f12475217c7b6e1d605`, Apache-2.0. Its Swift 6 manifest's only
package dependency is swift-atomics >=1.3.1, already pinned in Squidra. SwiftNIO
is declared directly at its existing locked version to expose the existing
NIOConcurrencyHelpers product. Resolving adds only the SDK repository pin;
existing dependency versions/revisions remain unchanged.
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
Required Linux/macOS CI must qualify the pinned graph before merge.

End-to-end model/tool/event correlation, host HTTP IDs, durable run integration
and any optional remote exporter remain separate tasks under SQD-030. A future
exporter must preserve the same content restrictions and require explicit host
configuration. Rollback removes this isolated foundation and its dependency pin;
no database migration or server behavior changes here.
