# ADR-004: Idempotency keys and ledger/journal separation

- Status: **Accepted** (maintainer approval, 2026-10-31)
- Date: 2026-10-29
- Sources: SRS §4.2 (+ §4.1, P-09, SQD-007); SDD §4.4 + §6.2 (+ §5.1, §13.2)
- Implements: T00 executable task 1 (idempotency)

## Context

SRS §4.2 requires a unique key per logical command with constraint
`UNIQUE(actorId, toolName, idempotencyKey)` plus a normalized argument
fingerprint; reuse of a key with different arguments is a conflict
error; the final result is persisted and returned on retry; external
non-transactional calls use outbox/reconciliation with a
provider-side identifier when available; external exactly-once is not
guaranteed without provider support.

SDD §4.4 agrees in prose ("unique per actor + operation + target",
same key + different parameters = `CONFLICT`, reserve-then-reconcile)
but §6.2 models both `action_ledger.idempotency_key` and
`world_events.idempotency_key` as *globally* unique, which is stricter
than — and incompatible with — the SRS composite key.

## Decision

1. **Ledger constraint is the SRS composite key.**
   `action_ledger` enforces `UNIQUE(actorId, toolName, idempotencyKey)`.
   The SDD §6.2 global unique on the ledger is not adopted: two actors
   (or two tools) must never collide on equal key strings.
2. **Canonical fingerprint decides conflicts.** The fingerprint covers
   actor, tool name **and version**, target, canonical (normalized)
   arguments and scope. Key reuse with an identical fingerprint returns
   the persisted result (`already_applied`, SRS §4.1); any fingerprint
   mismatch — including a different target — is `CONFLICT` (HTTP 409
   at the API).
3. **Ledger and journal are separate idempotency domains.**
   - The *action ledger* records reservations and results of tool
     executions (keys above).
   - The *event journal* (`EventStore.append`, SRS §3.1) keeps its own
     key and `expectedVersion` for optimistic concurrency on the event
     stream (see ADR-005). Journal deduplication never consults ledger
     keys and vice versa.
4. **Ordering is durable-first** (SRS P-09, SDD §13.2): reserve in the
   ledger before the call; persist the result before confirmation; on
   unknown outcome (crash between effect and finalization), reconcile
   against the provider/target before any new attempt — never blind
   retry. A provider without idempotency that cannot be reconciled
   yields `unknown`, never a fabricated success.

## Consequences

- T02/T03 migrations implement the composite unique + fingerprint
   columns; the SDD §6.2 sketch must be adapted, not copied literally.
- SQD-007 tests same-key/same-args replay, same-key/different-args
   conflict (including different target), and concurrent double-submit
   single-effect.
- SQD-028 builds crash recovery on rules 3–4.

## Verification

- `IDEMP-007` style tests: replay returns identical persisted result;
   conflicting reuse → `CONFLICT`; concurrent duplicate reservation →
   one winner; crash-before-reservation / after-effect /
   before-finalization each reconcile to exactly one effect or explicit
   `unknown`.
