# ADR-007: Versioned envelopes, cancellation, deadlines

- Status: **Proposed** (T00; awaits human contract review)
- Date: 2026-10-29
- Sources: SRS P-07, FR-TOOL-05, NFR-08, §5, SQD-011; SDD §4.1, §10, §11
- Implements: T00 executable task 3 (envelopes, cancellation, deadlines)

## Context

SDD §10 defines a stable error envelope (code, public message,
`requestId`, filtered details), per-route timeouts/pagination/size
limits/auth, 202/201 semantics for runs/observations, resumable AG-UI
SSE, and versioned `RunState`. SRS requires versioned APIs with
documented breaking changes (NFR-08), typed secret-free errors
(FR-TOOL-05), `runId`/`traceId` correlation (P-07), cancellable
attempts (SRS §5) and truthful cancellation (SQD-011). All I/O
interfaces are `Sendable`/`async` with cancellation and deadlines
(SDD §4.1).

## Decision

1. **Error envelope** (normative schema:
   `Schemas/contracts/envelope.schema.json`):
   `{code, message, requestId, schemaVersion, details?}` where `code`
   is a stable machine string (`POLICY_DENIED`, `CONFLICT`, …),
   `message` is public human text without secrets or PII, `requestId`
   is always present, `schemaVersion` is `"1"`, and `details` is an
   optional filtered object bound by the route's schema. Unknown or
   unlisted error shapes are a contract violation.
2. **Response conventions.** Every API response carries `requestId`
   (header and/or body); mutations return the relevant identifiers;
   listings are explicitly paginated and size-bounded; SSE streams
   carry monotonic per-run event ids for resume (T05 details the
   AG-UI mapping).
3. **Versioning.** URL major version (`/api/v1`, SDD §10); every
   external DTO carries `schemaVersion`; tool definitions carry semver
   (`name/version`, SRS FR-TOOL-01, SDD §4.3). Breaking changes ship a
   new version with documented migration (NFR-08). Compatibility is
   assessed against existing consumers and their published schemas.
   Adding a property to a strict object (`additionalProperties: false`),
   including this error envelope, is a breaking change even when the
   property is optional: old validators reject responses containing it.
   Such additions require a new `schemaVersion` and a separate schema;
   retain the old schema and response shape for consumers using that
   version. Same-version additions are allowed only at extension points
   that the existing schema already permits, subject to their filtering
   rules. The route-bound `details` object is not an unrestricted
   extension point; its route schema must also permit the addition.
4. **Cancellation is cooperative and truthful.** A cancellation token
   propagates API → runtime → adapters (SRS §5); cancellation of a
   run yields terminal `CANCELLED`; no unconfirmed mutation is ever
   presented as succeeded (SQD-011). Durable approval waits end by
   decision, expiry, or explicit withdrawal — also observed as
   cancellation of the waiter, not as approval.
5. **Three distinct clocks** (ADR-001): (a) per-attempt timeout from
   `ToolDefinition.timeoutMs`; (b) run active-duration budget
   (default 180 s, durable waits excluded) producing `TIMED_OUT`;
   (c) approval TTL (default 10 min) producing expiry, never implicit
   consent. An attempt timeout does not by itself time out the run;
   run timeout never forges an approval decision.

## Consequences

- T04 implements the envelope + `requestId` + auth at the HTTP
  boundary; T05 the resumable event stream; SQD-006 the tool-side
  schema validation reusing the same envelope.
- Clients can rely on `code` for control flow and on `requestId` for
  support correlation (P-07, SDD §11 attributes).
- Secrets/PII in errors, traces or prompts are release-blocking
  (SRS §10, NFR-03).

## Verification

- Contract tests: error-shape conformance per route; unknown-field
  rejection on strict DTOs; cancel-mid-tool-call → `CANCELLED` with no
  confirmed effect; attempt-timeout vs run-`TIMED_OUT` vs approval
  expiry distinguished on fixtures.
- Versioning checks: the v1 envelope rejects an added top-level field;
  a future version validates that field only against its separate
  schema, while the unchanged v1 response still validates against v1.
