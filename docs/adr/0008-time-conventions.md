# ADR-008: Time conventions

- Status: **Proposed** (T00; awaits human contract review)
- Date: 2026-10-29
- Sources: SRS P-04/P-05, §7.1–§7.3, SQD-013/014/015/017/018; SDD §4.1, §6.1–§6.4
- Implements: T00 executable task 3 (time conventions)

## Context

SRS P-04 requires explicit `occurredAt`/`observedAt`/`recordedAt`,
`validFrom`/`validTo` and timezone where applicable; §7 defines the
`WorldEvent` triple, bitemporal projection (`stateAt(validTime,
knowledgeTime)`, `changesBetween`), SI units with explicit frames, and
unknown-≠-false uncertainty (P-05). SQD-017 requires local dates
persisted with their IANA zone and DST-safe relative expressions;
SQD-018 requires documented bound inclusivity.

SDD §4.1 fixes UTC instants, IANA zones kept for recurring events and
relative expressions, non-interchangeable timestamps and versioned
DTOs; §6.1–§6.4 fix valid vs transaction time, `[valid_from,
valid_to)` half-open intervals, `TIMESTAMPTZ` storage, confidence in
`[0,1]`, nullable `occurred_at`, append-only journal with
sequence-ordered projection, and deterministic re-projection.

## Decision

1. **Wire and storage.** Instants are UTC `TIMESTAMPTZ` in storage and
   RFC 3339 with explicit offset (`Z` for UTC) on the wire and in DTOs.
2. **IANA zones preserved.** Wherever the SRS requires local meaning —
   relative expressions (SQD-017), recurring intentions, user-facing
   schedules — the UTC instant is persisted together with its IANA
   zone; DST transitions are tested, ambiguity is surfaced, never
   silently resolved.
3. **Triple timestamps, never interchangeable** (SRS P-04, SDD §4.1):
   `occurredAt` (when it happened in the world; **nullable** — unknown
   allowed, SDD §6.2), `observedAt` (when sensed), `recordedAt` (when
   journaled). `recordedAt` is not a substitute for transaction time
   (SDD §6.2).
4. **Intervals are `[start, end)`** with `NULL` end meaning open-ended
   (SQD-018 bound inclusivity frozen here). Confidence is a `[0,1]`
   `CHECK`. Unknown differs from false in every query and projection
   (SRS P-05).
5. **Bitemporal discipline** (SRS §7.2, SDD §6.1): valid time vs
   transaction time with `tx_to > tx_from`; corrections close the
   previous transactional version and append a new one; the raw
   journal stays append-only; projectors apply journal-sequence order,
   are idempotent, and re-project deterministically (SDD §6.4).
6. **Injected clocks.** Durations use the monotonic clock, timestamps
   the wall clock, via the injectable `Clock`/`ClockPort`
   (`now`, `timezone`, `monotonicElapsed`); the two are never mixed,
   and tests inject fixed clocks (determinism, SRS P-01).

## Consequences

- T02/T03 migrations enforce `TIMESTAMPTZ`, half-open intervals,
  `tx_to > tx_from`, confidence range and append-only journal tables.
- SQD-013/014/015/017/018 implement triple timestamps, bitemporal
  queries, IANA persistence and interval algebra against these rules.
- Late observations order correctly by `(occurredAt, observedAt,
  journal sequence)` without rewriting history.

## Verification

- `TIME-013`/`TIME-014`/`TZ-017`/`INTERVAL-018` style tests: late
  observation ordering, DST-boundary relative expressions,
  `[start, end)` edge inclusivity, bitemporal correction preserving
  prior knowledge, unknown-`occurredAt` handling.
