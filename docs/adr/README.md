# SQUIDRA Architecture Decision Records

T00 contract-resolution record. All ADRs below are **Accepted** following
explicit maintainer approval on 31 October 2026, per T00 acceptance criteria.

## Sources (verified)

| Document | Version | SHA-256 |
|---|---|---|
| SRS `SQUIDRA_SRS_User_Stories.pdf` | 1.0, 29 Oct 2026 | `714fe24b…fe15816` |
| SDD `SQUIDRA_Software_Design_Document_v0.1.pdf` | 0.1, 29 Oct 2026 | `1c029324…be8ffb` |

Full fingerprints are in the plan's `sources.json`. The SRS is written in
French; citations below give the exact section and a short English gloss.

**Numbering note.** This repo series (`ADR-000`–`ADR-008`) is distinct from
the SDD's own §14 table (`ADR-001`–`ADR-010`). References to the latter are
always written `SDD §14 ADR-00X`.

## Index

| ADR | Title | Freezes |
|---|---|---|
| [ADR-000](0000-srs-precedence.md) | SRS precedence and change control | Contract authority |
| [ADR-001](0001-run-budgets.md) | Run budgets, steps, retries, loop detection | 20 steps / 15 calls / depth 3 / 180 s / 2 retries |
| [ADR-002](0002-fsm-states.md) | Public FSM states and internal substates | SRS public states + SDD substates + terminal codes |
| [ADR-003](0003-risk-scale.md) | Authoritative risk scale | R0–R4, SDD L-class mapping, approval rules |
| [ADR-004](0004-idempotency.md) | Idempotency keys and ledger separation | `UNIQUE(actorId, toolName, idempotencyKey)` |
| [ADR-005](0005-swift-ports.md) | Swift port names and documentation aliases | `LanguageModel`, `ModelPort` alias, `expectedVersion` |
| [ADR-006](0006-health-routes.md) | Health and readiness routes | Canonical routes + SRS aliases |
| [ADR-007](0007-envelopes-cancellation-deadlines.md) | Envelopes, cancellation, deadlines | Error envelope, 3-clock model |
| [ADR-008](0008-time-conventions.md) | Time conventions | UTC/RFC 3339, IANA zones, `[start, end)` intervals |

## Master mapping table (SRS ↔ SDD)

| Topic | SRS (normative) | SDD (proposal) | Frozen decision |
|---|---|---|---|
| Contract authority | v1.0 "proposition de référence" | v0.1 "proposition technique à valider" | SRS wins; see ADR-000 |
| Steps / tool calls / depth | §5: 20 / 15 / 3 | §5: 20 / 30 / 2 | 20 / 15 / 3; see ADR-001 |
| Sync run duration | §5: ≤ 180 s | §5: 180 "secondes interactives" | 180 s active time, durable waits excluded; ADR-001 |
| Retries | §5: ≤ 2 with backoff | — (reconcile, §5.1) | ≤ 2 retries, attempts consume call budget; ADR-001 |
| Loop detection | §5: hash, stop after 3 no-progress repetitions | §5.1: fingerprint + `LOOP_DETECTED` | BUDGET_EXCEEDED + code `LOOP_DETECTED`; ADR-001/002 |
| Approval TTL | §5: default 10 min | §5: durable wait, no worker | TTL default 10 min, durable wait; ADR-001 |
| FSM states | §5 coarse states | §5 detailed states | SRS public + SDD substates; ADR-002 |
| Terminal states | §5: incl. `TIMED_OUT` | §5: omits `TIMED_OUT` | SRS set incl. `TIMED_OUT`; ADR-002 |
| `DENIED` | — (policy refusal, §6) | §5: `POLICY_CHECK → DENIED` | Typed failure `FAILED`/`POLICY_DENIED`; ADR-002 |
| Risk scale | §6: R0–R4 | §9: L0–L3 | R0–R4; L→R mapping; ADR-003 |
| R2 approval | §6: mandatory human approval | §9 L3: mandatory for external message | Mandatory, no policy waiver; ADR-003 |
| Ledger key | §4.2: `UNIQUE(actorId, toolName, idempotencyKey)` | §6.2: global `UNIQUE(idempotency_key)` | SRS composite key; ADR-004 |
| Key reuse, different args | §4.2: conflict error | §4.4: `CONFLICT` | `CONFLICT` (409); ADR-004 |
| EventStore append | §3.1: `(event, expectedVersion, idempotencyKey)` | §4.2: `(event, idempotencyKey)` | Keep `expectedVersion`; ADR-004/005 |
| Model port | §3.1: `ModelPort.infer` | §4.2: `LanguageModel.generate` | Swift `LanguageModel`, doc alias `ModelPort`; ADR-005 |
| World port | §3.1: `WorldQueryPort` + `EventStore` | §4.2: `WorldRepository` | Swift `WorldRepository`, doc aliases; ADR-005 |
| Probes | SQD-001: `/health`, `/ready` | §10: `/health/live`, `/health/ready` | SDD canonical + SRS aliases; ADR-006 |
| Error envelope | FR-TOOL-05: typed, no secrets | §10: code/message/requestId/details | Schema in `Schemas/contracts`; ADR-007 |
| Time | P-04, §7, SQD-013/017/018 | §4.1, §6.2 | UTC + IANA + `[start, end)`; ADR-008 |
| `occurredAt` | §7.1: required field | §6.2: `occurred_at NULL` | Nullable (unknown allowed); ADR-008 |

## Review checklist (for the maintainer)

- [x] Source links above resolve to the cited SRS/SDD sections.
- [x] Decision table matches the cited discrepancies (no silent deviation).
- [x] Frozen values equal T00 acceptance: SRS precedence; 20/15/3/180 s/2
      retries; R0–R4; `UNIQUE(actorId, toolName, idempotencyKey)`.
- [x] Administrative prerequisites confirmed (plan §8: first commit identity,
      default branch, reviewer rules) before dependent work leaves draft.
