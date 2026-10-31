# ADR-005: Swift port names and documentation aliases

- Status: **Proposed** (T00; awaits human contract review)
- Date: 2026-10-29
- Sources: SRS §3.1 (+ P-06, SQD-003); SDD §3 + §4.1 + §4.2
- Implements: T00 executable task 2 (ports)

## Context

SRS §3.1 specifies documentation-level ports: `ModelPort`
(`infer(request: ModelRequest) -> ModelResult`), `ToolPort`,
`PolicyPort`, `EventStore` (`append(event, expectedVersion,
idempotencyKey)`), `WorldQueryPort` (`stateAt(entityId, instant)`,
`changesBetween(start, end)`), `PerceptionPort`, `ApprovalPort`
(request/resolve with TTL), `ClockPort` (`now()`, `timezone()`,
`monotonicElapsed()`), `SandboxPort`.

SDD §3–§4.2 specifies Swift protocols: `LanguageModel`
(`generate(_ request: ModelRequest)`), `ToolRegistry`/`ToolExecutor`,
`PolicyEngine`, `WorldRepository` (`append(_:idempotencyKey:)`,
`state(validAt:knownAt:)`, `changes(from:to:)`), `WorldProjector`,
`VisionModel`/`EntityResolver`, `MemoryStore`/`IntentionStore`,
`ApprovalStore`, `RunStore`/`RunEngine`, `ContextProvider`, and domain
`Clock`. SDD `WorldRepository.append` drops `expectedVersion`.

## Decision

1. **Swift code uses the SDD names.** Protocols, modules and imports
   follow SDD §3–§4.2 (`LanguageModel`, `WorldRepository`, …).
2. **SRS names are documentation aliases**, kept in prose, issue text
   and doc comments so SRS traceability survives:

| SRS alias (§3.1) | Swift port (SDD) | Notes |
|---|---|---|
| `ModelPort` | `LanguageModel` | `generate(_:)`; request/response DTOs versioned |
| `ToolPort` | `ToolRegistry` + `ToolExecutor` | Resolve-then-execute split |
| `PolicyPort` | `PolicyEngine` | `evaluate(_:in:)` |
| `EventStore` (append path) | `WorldRepository.append` | Keeps `expectedVersion` (rule 3) |
| `WorldQueryPort` | `WorldRepository.state/changes` | Bitemporal queries |
| `PerceptionPort` | `VisionModel` + `EntityResolver` | Ingest vs association split |
| `ApprovalPort` | `ApprovalStore` | TTL + exact-digest decisions (ADR-003) |
| `ClockPort` | `Clock` (SquidraDomain) | `now` / timezone / monotonic; injectable |
| `SandboxPort` | Isolation adapters | Detailed in a later sandbox issue |
| — | `RunStore`, `RunEngine`, `WorldProjector`, `ContextProvider`, stores | SDD-only harness internals; no SRS counterpart |

3. **Journal append retains `expectedVersion`.** The event-journal
   append is `(event, expectedVersion, idempotencyKey)` per SRS §3.1:
   optimistic concurrency on the stream plus the journal's own
   deduplication key, separate from the action-ledger key (ADR-004).
   The SDD §4.2 two-parameter `append` is extended, not copied.
4. **All I/O ports are `Sendable`, `async`/`await`, and accept
   cancellation and deadlines** (SDD §4.1; SRS §5 cancellable
   attempts). Read/write ports are split where the SDD does so
   (`ToolRegistry`/`ToolExecutor`); merged ports keep both paths
   documented.

## Consequences

- T01 creates targets with SDD names; doc comments cite the SRS alias
  and section (e.g. `/// SRS §3.1 ModelPort`).
- SQD-003 (provider substitution) tests against `LanguageModel`;
  swapping Meta/fake/local adapters touches no domain code (P-06,
  SDD §2.3 dependency rule).
- No HTTP, SQL or model-SDK types in `SquidraDomain` (SDD §2.3).

## Verification

- `UT-MODEL-003` style tests: fake `LanguageModel` substitution,
  fallback and typed errors; journal append with stale
  `expectedVersion` rejected; dependency-lint proving domain purity.
