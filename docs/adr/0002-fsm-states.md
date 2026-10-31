# ADR-002: Public FSM states, internal substates, terminal codes

- Status: **Proposed** (T00; awaits human contract review)
- Date: 2026-10-29
- Sources: SRS §5; SDD §5 + §5.1; SRS §6 (approvals); SDD §10 (`RunState`)
- Implements: T00 executable task 1 (FSM)

## Context

SRS §5 defines a coarse FSM: `CREATED → VALIDATING → CONTEXT_LOADING →
PLANNING → [WAITING_APPROVAL | EXECUTING_TOOL | RESPONDING] →
COMPLETED`, with exits `FAILED`, `CANCELLED`, `TIMED_OUT`,
`BUDGET_EXCEEDED`. States are persisted, transitions controlled and
logged, and no terminal state may resume silently.

SDD §5 defines a finer FSM (`REASONING`, `PROPOSED`, `POLICY_CHECK`,
`APPROVAL_REQUIRED`, `EXECUTING`, `OBSERVING_RESULT`, `PERSISTING`,
`DENIED`, …), optimistic concurrency by `runId` version, durable
`WAITING_APPROVAL` without a worker, and `LOOP_DETECTED` termination
(§5.1). Its any-transition list omits `TIMED_OUT`, and it names the
planning activity `REASONING` where the SRS says `PLANNING`.

## Decision

Two-level state model:

- **Public states** (exposed via API `RunState`, SDD §10) are exactly
  the SRS §5 set: `CREATED`, `VALIDATING`, `CONTEXT_LOADING`,
  `PLANNING`, `WAITING_APPROVAL`, `EXECUTING_TOOL`, `RESPONDING`,
  `COMPLETED`, `FAILED`, `CANCELLED`, `TIMED_OUT`, `BUDGET_EXCEEDED`.
- **Internal substates** are the SDD §5 detail, always mapped to one
  public state:

| Internal (SDD) | Public (SRS) | Note |
|---|---|---|
| `REASONING` | `PLANNING` | Same activity; SRS name is public |
| `PROPOSED` | `PLANNING` | Validated proposal exists, not yet dispatched |
| `POLICY_CHECK` | `VALIDATING` | Policy/validation are validation substates |
| `APPROVAL_REQUIRED` | `WAITING_APPROVAL` | Need identified, request not yet / being dispatched |
| `WAITING_APPROVAL` | `WAITING_APPROVAL` | Durable wait, holds no worker |
| `EXECUTING` | `EXECUTING_TOOL` | — |
| `OBSERVING_RESULT` | `EXECUTING_TOOL` | — |
| `PERSISTING` | `EXECUTING_TOOL` | Durable result before confirmation |
| `RESPONDING` (return path) | `RESPONDING` | SDD returns to `REASONING` or `COMPLETED` |

- **Terminal codes.** The public terminal-state enum stays the SRS set.
  SDD-only outcomes become typed terminal *codes* on a `Run`'s terminal
  reason `{state, code}`:
  - `POLICY_CHECK → DENIED` becomes `FAILED` with code `POLICY_DENIED`
    (a typed public failure, never a silent drop).
  - Loop trip becomes `BUDGET_EXCEEDED` with code `LOOP_DETECTED`
    (repetition-budget exhaustion; ADR-001).
- Preserved from both: `TIMED_OUT` (SRS; SDD's omission is not
  adopted), optimistic-concurrency transitions (single winner per
  `runId` version, SDD §5), durable `WAITING_APPROVAL` (both), and no
  silent resume of terminal states (SRS §5).

## Consequences

- API consumers and the Web UI (T06) switch on 12 stable public states;
  operators and traces (SQD-030) see substate + terminal code detail.
- `DENIED` and `LOOP_DETECTED` never appear as public states; tests
  assert `{state, code}` pairs.
- T05/SQD-005 implement the transition table; invalid transitions are
  rejected, not coerced.

## Verification

- `FSM-005` style tests: legal/illegal transition matrix, concurrent
  transition single-winner, `POLICY_DENIED`/`LOOP_DETECTED` code
  assertions, terminal-state immutability, `TIMED_OUT` on active-clock
  exhaustion only.
