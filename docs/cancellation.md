# Cancellation and truthful status (SQD-011)

Run `bash Scripts/test-issue.sh SQD-011` to qualify the cancellation path. On
Colima installations that need explicit loopback forwarding, set
`SQUIDRA_CONTAINER_ENGINE="$PWD/Scripts/colima-test-engine.py"`. This command fails
if any child suite fails, selects no tests or reports incomplete execution.
Each child retains its detailed report under `.build/issue-tests/`.

An authenticated empty POST to `/api/v1/runs/:run/cancel` signals the locally
owned worker. HTTP 202 acknowledges the signal; GET status and persisted events
report completion. Cancellation propagates through the coordinator, runtime,
model router and tool gateway using Swift task cancellation and bounded port
deadlines. Runtime terminal persistence and publication use owned, awaited
cleanup. A success already being published is preserved. An orphaned active run
requires recovery; the endpoint never invents a terminal state for it.

The PostgreSQL HTTP test interrupts the real read engine during its planner,
world query and answer model. It independently reloads the runtime checkpoint,
checks CANCELLED and its terminal code, verifies cancelled publication without
output, and checks replay contains only start and terminal events. The injected
models and query delays are deterministic fixtures, not live provider quality
measurements. Separate worker tests cover cancellation racing the durable claim.

Durable approval waits do not keep a task alive. Explicit withdrawal is recorded
by the approval service; resuming that waiter persists CANCELLED and cannot
dispatch. Denial and expiry remain distinct policy failures. Terminal waits cannot
be resumed again.

Cancellation never proves an external rollback. A mutating gateway call that has
begun dispatch joins a fresh bounded ledger cleanup, recording unknown rather than
success. Its original deadline or cancelled caller cannot suppress that cleanup.
If cleanup fails, the caller receives outcomeUnconfirmed. Repeating an unknown
command returns reconciliationRequired and grants no dispatch permit. Only
independent provider/target evidence can resolve the existing record; its
idempotency key is preserved.

The real PostgreSQL ledger test commits a fixture effect before cancelling or
expiring the gateway call, then opens a new ledger over a second connection. Both
cases reload unknown with no result, retain the committed effect, and require
explicit reconciliation. A verified fixture receipt resolves the existing effect
to succeeded; the executor is called once. This tests lost acknowledgement of an
actual committed fixture effect, without claiming qualification of a remote
provider or a process crash. Process-crash recovery belongs to SQD-028.

The acceptance suites are T14-RUN (runtime), SQD-009 (approval wait), SQD-008
(gateway), SQD-007 (PostgreSQL ledger), and T05-HTTP (HTTP through runtime and SQL).
They are already included in the full local gate. Hosted Linux/macOS qualification
will be rerun when the authorized temporary CI suspension ends.
