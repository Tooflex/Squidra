# Frozen contracts (T00)

Normative machine-readable contracts. Status: **Proposed** — effective
only after the maintainer reviews the [ADRs](../../docs/adr/README.md).

## Index

| File | Freezes | ADR |
|---|---|---|
| [envelope.schema.json](envelope.schema.json) | API error envelope v1 (`code`, `message`, `requestId`, `schemaVersion`, `details?`) | [ADR-007](../../docs/adr/0007-envelopes-cancellation-deadlines.md) |

## Scope: what T00 freezes vs defers

Frozen here:

- The error-envelope shape and its required fields (above).
- Envelope conventions: `requestId` on every response, `schemaVersion`
  on every external DTO, URL major versions, semver tool versions
  (ADR-007).
- Time representation rules referenced by future schemas: UTC RFC 3339
  instants, IANA zones alongside local meaning, `[start, end)`
  intervals, nullable `occurredAt` (ADR-008).

Deferred to later issues (not invented here):

- Full `WorldEvent` / `SpatialFact` / `ToolDefinition` / `ActionContext`
  / `Run` DTO schemas → SQD-006, SQD-013/014, T13/T14.
- AG-UI SSE event schemas and resume protocol → T05.
- SQL migrations and physical constraints → T02/T03.
- API success payloads per route → T04/T05.

## Change control

Amendments follow ADR-000: a new or superseding ADR, maintainer
review, then a versioned schema update. Breaking schema changes ship a
new `schemaVersion` and a separate schema with a documented migration;
retain the old schema and response shape for consumers using that
version. Adding even an optional field to an object with
`additionalProperties: false` is breaking for existing validators and
requires a new version. Same-version additions are allowed only at
extension points already permitted by the existing schema and its
route-specific filtering rules (ADR-007).
