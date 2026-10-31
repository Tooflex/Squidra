# ADR-009: Bounded AG-UI producer and resumable run transport

- Status: Proposed in the linked PR; acceptance occurs on its authorized merge.
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

The future HTTP implementation must preserve the existing bearer/origin/body
boundary and bounded connection deadline. Add Last-Event-ID to preflight handling
only with its route and tests. A closed SSE connection alone does not mean a run
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

No route, stream server, database migration, background worker or reconnect
integration is implemented by this contract PR. T05 stays open for those steps.
No package version changes are needed. Rollback removes the isolated producer,
its tests and immutable qualification artifacts.
