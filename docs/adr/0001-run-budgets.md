# ADR-001: Run budgets, steps, retries, loop detection, approval TTL

- Status: **Proposed** (T00; awaits human contract review)
- Date: 2026-10-29
- Sources: SRS §5 (+ §6 approvals); SDD §5 + §5.1
- Implements: T00 executable task 1 (budgets)

## Context

SRS §5 fixes initial per-run budgets: ≤ 20 steps, delegation depth ≤ 3,
≤ 15 tool calls, synchronous run ≤ 180 s, ≤ 2 retries with backoff per
tool, explicit per-profile token budget, loop detection by call/state
hash with stop after 3 repetitions without progress, and approval
expiration default 10 min.

SDD §5 proposes different limits: 20 steps, **30** tool calls,
delegation depth **2**, 180 "secondes interactives"; §5.1 terminates
loops with `LOOP_DETECTED` and persists `WAITING_APPROVAL` without
consuming a worker.

## Decision

SRS values win (ADR-000). Frozen budgets, enforced host-side:

| Budget | Frozen value | Counts |
|---|---|---|
| Steps | ≤ 20 | Validated proposals (see below) |
| Tool-call attempts | ≤ 15 | Every execution attempt, **including retries** |
| Delegation depth | ≤ 3 | Levels below the principal run |
| Active run duration | ≤ 180 s | Wall time minus durable waits |
| Retries | ≤ 2 per tool invocation | With backoff; same idempotency key |
| Loop | Stop after 3 no-progress repetitions | Identical semantic proposal/state at the iteration boundary, no verified task progress |
| Approval TTL | Default 10 min, configurable | Per approval; independent clock |
| Tokens | Explicit budget per profile | Measured, never assumed |

Definitions:

- **Step.** One agent-loop iteration that yields a *validated* proposal:
  each entry into `PLANNING`/`REASONING` (ADR-002) producing a proposal
  that passes schema/policy validation consumes exactly one step,
  whether the proposal is a tool call, a delegation request or a final
  response. Rejected proposals consume no step but are logged.
- **Attempt.** One execution try of a validated tool proposal. Retries
  re-execute the same proposal under the same idempotency key
  (ADR-004); each attempt consumes the tool-call budget. Hence at most
  15 attempts per run even though 20 steps are allowed (non-tool
  proposals such as responding consume steps only).
- **Progress (loop detection).** A verified change relevant to the task:
  newly learned evidence that changes the task's known facts or resolves
  an uncertainty, or a confirmed durable effect that advances an explicit
  task objective. Each tool/result contract defines the evidence for
  such progress. Routine FSM transitions, ledger reservations, retries,
  new identifiers/timestamps, and repeated unchanged observations are
  bookkeeping and never count as progress on their own.
- **Repetition accounting.** Compare iterations at a fixed boundary:
  after validation and any execution/result persistence, before the next
  planning iteration. Use the public state captured at the start of the
  iteration and a canonical semantic proposal hash (operation, tool
  version, target, arguments, and effective scope). Exclude incidental
  request/trace identifiers and idempotency keys so regenerating them
  cannot evade detection. Include rejected proposals in this accounting
  even though they consume no step. The first no-progress occurrence of
  a fingerprint sets its consecutive count to 1; another identical
  no-progress iteration increments it. A different fingerprint starts
  at 1; verified progress resets the count to 0. At 3, terminate as
  `BUDGET_EXCEEDED` with terminal code `LOOP_DETECTED` (ADR-002), before
  dispatching another iteration. Persist the fingerprint and count with
  the run checkpoint so restart does not reset this guard.
- **Clocks.** Three independent clocks (see ADR-007): per-attempt
  timeout (`ToolDefinition.timeoutMs`), run active-duration budget
  (180 s; durable `WAITING_APPROVAL` consumes none of it), and approval
  TTL (default 10 min). A pending approval must never be invalidated by
  run active time, and a long approval wait must never consume a worker
  (SRS §6 durable approval; SDD §5).

Budgets are initial, configurable-per-profile values, not SLAs (SRS
§5). Exceeding a budget terminates the run explicitly (`TIMED_OUT`,
`BUDGET_EXCEEDED`, or `CANCELLED`); terminal states never resume
silently (SRS §5; ADR-002).

## Consequences

- T01/T05 implement host-side counters; SQD-005 tests bounds, timeouts
  and explicit terminal states.
- Attempts consuming the call budget bounds worst-case external effects
  to 15 per run, retries included.
- The SDD's 30-call / depth-2 proposal is rejected; implementations
  must not encode it.

## Verification

- `FSM-005` style tests: exceed each budget on fixtures, assert the
  exact terminal state and code; assert a 10-minute approval wait holds
  no worker and stays valid while active time is paused.
- Repeat an unchanged read three times while advancing FSM substates and
  generating fresh ledger/request identifiers: assert `LOOP_DETECTED`
  before a fourth dispatch. Repeat with rejected proposals and across a
  checkpoint/restart. Verify that new task-relevant evidence or a
  confirmed objective-advancing effect resets the counter, while a new
  timestamp on otherwise unchanged evidence does not.
