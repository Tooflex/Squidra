# Run recovery

`RunRecovery` is a host recovery operation for a worker that has stopped. It is
not a live takeover endpoint: the host must join the old worker, or verify its
process has exited, before calling it. No HTTP route or startup scan activates
this operation yet. CAS prevents stale checkpoint writes; CAS alone cannot revoke
a tool permit already issued to a still-running process.

The caller supplies an actor, run, and the exact checkpoint version inspected.
Recovery validates identity and checkpoint structure, preserves all budgets,
counters and invocation keys, and charges elapsed wall time against the persisted
active deadline. Downtime does not replenish the budget. An expired checkpoint
terminates TIMED_OUT. A wall-clock regression fails closed. Durable approval waits
retain their original checkpoint and are returned to the existing ApprovalWait
continuation, which validates binding, decision and TTL before resuming.

Before recovering an attempted tool call, the host must locate its ledger record.
The record's actor, run, idempotency key and command fingerprint must match the
checkpoint. Pending/unknown outcomes go through an injected RunEffectVerifier.
Only independently verified provider/target evidence may produce an ActionResult;
model text and a database-status guess are not evidence. The confirmed result is
persisted in the ledger before the runtime continuation is returned. Nil,
unavailable verification or timeout produces explicit FAILED/RECOVERY_REQUIRED,
with the attempted effect still unknown. Missing ledger identity also terminates
explicitly; it cannot authorize a fresh key or execution.

An unclaimed reserved action can resume with the same key under existing retry
limits and backoff. Already final ledger results are reused. Recovery itself has
no tool executor, emits no dispatch permit and does not reset attempts. The
returned RunController retains normal policy, call-budget and persistence gates.
The caller must still revalidate policy and approval before another effect.

A durable version bump precedes effect verification. Ambiguous or failed writes
return no continuation. A second write records the reconciled invocation; if its
acknowledgement is lost, a later recovery reloads the final ledger outcome rather
than executing again. Recovery I/O is charged by the restored controller before
its next transition or dispatch reservation.

`SQD-028-UNIT` covers budget preservation, clock regression, expiry, stale
controllers, lost acknowledgements, approval waiting, missing ledger identity,
and verified/unverifiable effects. This is the checkpoint component of SQD-028;
Host activation and end-to-end application resumption are still pending. This document does not claim the full issue complete.

## PostgreSQL checkpoint qualification

`bash Scripts/test-issue.sh SQD-028-DURABLE` uses an isolated PostgreSQL database
and a second client to reload all runtime and action state. Six scenarios cover
an unclaimed reservation, a pending call with verified non-application, a committed
fixture receipt without a result, an already-persisted result, loss of the recovery
claim acknowledgement, and loss of the reconciled checkpoint acknowledgement.
The last two faults are injected after the real database transaction commits.

Confirmed effects resume through RESPONDING to COMPLETED without a second effect;
non-application remains failure, and an unclaimed reservation retains retry state.
Every scenario checks the original key, one charged attempt, unchanged budget,
durable terminal state and zero or one receipt as appropriate. Reconciliation is
read-only against fixture receipts; it never recreates the effect. A lost final
checkpoint acknowledgement reloads the confirmed ledger result without repeating
the verifier or effect. The original controller performs no work during recovery.

This qualifies storage and lost-acknowledgement boundaries. It does not simulate
OS process death, network partition or a concurrent live worker. The separate process-kill harness below covers abrupt process death. Host
continuation activation remains required for the complete story.

## Actual process-crash qualification

`bash Scripts/test-issue.sh SQD-028-CRASH` builds the separate
`squidra-run-crash-fixture` executable under Tests/RunCrashFixture. It requires an
explicit fixture opt-in and isolated database credentials; it is not the server's
recovery interface. The harness owns one seed process at a time, waits for its
atomic marker written after durable SQL commits, sends SIGKILL to that exact
process, and verifies its exit before starting a fresh recovery process. Markers
contain fixture UUIDs and stage names, never credentials. Credentials stay in the
child environment. Temporary markers/logs and database containers are cleaned up.

Four stages cover reserved (no dispatch permit yet), pending (unverifiable effect),
committed effect, and durable result. An existing reserved row can now be claimed
atomically by ActionLedger.prepare after normal gateway authorization. Competing
claimants use the same version check; only one obtains a permit. Pending/unknown
rows still never grant another dispatch. This fixes the previously stranded
reservation after a crash between reserve and claim.

The reserved stage resumes with the original key, charges its second bounded
attempt, executes once and completes. The pending stage explicitly terminates
RECOVERY_REQUIRED without assuming the absent receipt proves non-application.
The effect and result stages complete from the confirmed receipt/result without
executing again. Each fresh process checks durable terminal state, exact attempt
count and zero/one effect as appropriate. Linux execution remains to be qualified
when hosted CI is restored; the local run uses macOS and real PostgreSQL.

This process fixture demonstrates the host sequence (old process exited, reload,
reconcile, continue) but does not activate automatic recovery in the application.
The server still needs a persisted task description and an owned startup/explicit
continuation path. SQD-028 remains open until that integration is complete.

## Persisted live read tasks

The live `PublishedReadRunCoordinator` now saves a `StoredReadRunTask` after
creating the event stream and before claiming publication or starting a worker.
A successful HTTP acceptance therefore has the original question, actor/run/
request/trace/thread IDs, planning entities, tool scope, answer intent, model
options, exact absolute deadline and runtime budget in PostgreSQL. Persistence
failure produces no worker. Stream creation, task save and publication claim are
separate durable steps; an incomplete admission may leave an unmanaged stream
and task, never an implicit permission to execute it.

`runtime/004_read_run_tasks.sql` binds the task to the exact stream identity and
rejects updates. Repeated identical saves are accepted; changing the task for an
existing run conflicts. The bounded versioned codec reconstructs validated
values, rejects unknown/noncanonical fields, and stores floating point deadline
and window values as exact bit strings. Loads are actor scoped. The task contains
private user text: it is not emitted in status, SSE, errors or tracing. Its
retention/purge lifecycle must be handled with the containing run data; it is
not a separate long-lived memory source.

This task is recovery input, not authority. Its saved scope or consent must not
bypass current host policy, restore elapsed budgets, or authorize a second live
worker. This step deliberately does not enable a startup scan: continuation of
ReadRunEngine phases, persisted answer/publication recovery, and verified worker
ownership still need integration before SQD-028 can close. The existing trace
and status routes continue to expose only their bounded public data.

T05-HTTP verifies persistence in the live submission path plus exact reload on a
second database client, idempotent save, conflicting replacement, actor isolation
and SQL update rejection. Existing recovery unit tests retain their seven budget,
approval and effect-reconciliation scenarios.

## Answer archive before runtime completion

The live read engine now writes its host-grounded answer through
`ReadRunCompletionStore` while the runtime is still `RESPONDING`, before clearing
the iteration and committing `COMPLETED`. PostgreSQL inserts only when the exact
actor/run/version is still responding and its persisted task has the same request
ID. The answer is bounded to 64 KiB and its exact encoded bytes are retained with
the responding checkpoint version. An identical retry is safe; a replacement
conflicts. The archive is private run data and follows the task's purge lifecycle.

An archive failure or lost acknowledgement returns `recoveryRequired` and leaves
the checkpoint for recovery instead of reporting a false completion or repeating
the model. An archive alone is not evidence that the run completed: later budget
expiry or cancellation can still prevent `COMPLETED`. A publisher must inspect
runtime terminal state, original binding, current authority and worker ownership
before using it. `StoredReadRunCompletion` exposes read-only bytes, not a new
GroundedAnswer proof or a tool/publication permit.

`runtime/005_read_run_completions.sql` adds the archive, scoped foreign keys and
an update guard. The live HTTP test checks that the archived JSON equals the
published grounded answer and its checkpoint precedes the completed runtime.
The engine test injects a lost write acknowledgement after capture and verifies
that no new model call occurs and the responding state survives.

The live server now owns a bounded publication-recovery worker. It scans only
actor-owned, unexpired streams whose publication lease expired, runtime is
`COMPLETED`, and responding archive predates the terminal runtime version. It
locks one stream (`SKIP LOCKED`), verifies task/request/thread/actor/subject scope,
and appends the archived answer, text frames and success marker atomically.
Migration `runtime/006_publication_recovery_index.sql` indexes running streams
by actor and lease order to support the bounded scan. The private PostgreSQL
path reuses stream chronology and byte-limit validation;
it exposes no public raw producer constructor or GroundedAnswer decoder.

A completed archive is already an owned run result: recovery makes it available
through the same authenticated status/SSE boundary without using saved scope as
new tool/model authority. Message identity derives from the existing run ID.
Concurrent workers produce one terminal stream; the former owner cannot publish
after its lease expires. The worker runs even without a model configuration and
is cancelled/joined before PostgreSQL shutdown. Idle polls are 250 ms. A corrupt
archive fails the service rather than skipping data or claiming success.

Nonterminal runtimes, live leases, expired retained streams and absent archives
are not candidates. Publication recovery never changes runtime state, reconciles
an effect, or dispatches a model/tool. Explicit `recoverExpired` also prefers a
completed valid archive; its existing recovery-required failure remains for
other expired runs. Earlier engine-phase continuation and abrupt-process server
qualification remain required before SQD-028 closes.

T05-HTTP covers real model-free server activation, unfinished-state exclusion,
foreign actor isolation, concurrent recovery winners, exact archived/published
JSON equality, stale-owner rejection and a second server instance without a
duplicate. The fixture advances the publication lease in SQL; it does not claim
to be the actual SIGKILL qualification.

## Completed-answer recovery across actual process deaths

`bash Scripts/test-issue.sh SQD-028-PUBLICATION-CRASH` now qualifies this completed
publication path with owned OS processes. The opt-in fixture runs the real
ReadRunEngine, ActionGateway, PostgreSQL read tool, task/result stores and runtime
FSM with an authored two-response local model. It marks the boundary only after
the runtime is completed, the answer archived and publication still running.
The harness kills that exact fixture PID with SIGKILL and waits for its exit.

A fresh normal `squidra serve` process, configured without a model host, waits for
the original database lease to expire naturally and recovers the answer. The
harness checks authenticated HTTP status and all six SSE frames, then a separate
verifier checks archived/published equality, unchanged terminal runtime version,
one step and one tool call. It SIGKILLs that server too, starts another normal
server, and requires byte-identical replay with no additional frames or runtime
changes. Markers contain only actor/run UUIDs and checkpoint version. Credentials
remain in child environments; the harness cleans up only its owned processes.

This is a real process-death test for the completed-before-publication boundary,
not a claim that an arbitrary early planning/tool phase resumes. The initial
fixture invokes the real engine directly; HTTP acceptance is covered by the live
integration suite. Earlier-phase continuation and effect-reconciliation activation
remain required before SQD-028 can close. No production hooks or migration are
added by this test.

## Explicit continuation before planning

`ReadRunEngine.resumeBeforePlanning` continues the original persisted request
from `CREATED`, `VALIDATING` or `CONTEXT_LOADING`. The host must first prove that
the previous worker stopped and reload the task; this is not a live takeover API.
The exact actor/run/trace and checkpoint version must match. Zero steps/calls and
absence of iteration/invocation checkpoints ensure no model or tool dispatch has
started. Planning and later states are rejected rather than retried implicitly.

The controller charges wall-clock downtime against the existing deadline, rejects
clock regression, preserves the original RunBudget, and writes a version increment
before returning control. Expired work becomes TIMED_OUT without a model call.
The continuation skips only already completed initial FSM transitions, may reload
bounded memory context, then uses the same planner, gateway policy, tool-call
accounting, grounding and answer archive as ordinary execution. It never creates
a second runtime row or refreshes a budget. CAS prevents the old controller from
writing after recovery, but the host's stopped-worker proof remains mandatory.

`T14-RUN` covers all three eligible states, unchanged IDs/budgets, charged downtime,
one planning/read/answer iteration, stale/repeated recovery refusal and expired or
already-planning checkpoints without a model call. `SQD-028-PREPLANNING-CRASH`
uses an owned fixture process stopped by SIGKILL in CONTEXT_LOADING. A separate
process reloads the exact task from PostgreSQL and invokes this continuation,
checks the original 15-second budget and one step/call, then leaves publication to
the normal model-free server after the original lease expires. A second server
still reads the identical six-event stream. The ordinary completed-boundary crash
fixture remains available separately.

This exposes and qualifies a real early continuation, but does not yet wire it to
automatic server ownership recovery. Persisted planning/tool artifacts, uncertain
model/effect handling and remaining application activation still block SQD-028.


## Saved planning continuation

The live engine archives a validated plan while the checkpoint is still PLANNING,
before reserving a proposal or issuing any tool permit. Migration
`runtime/007_read_run_plans.sql` binds this immutable, bounded archive to the
actor/run, original task request and exact planning checkpoint version. Identical
save retries remain valid after later progress; replacement conflicts. Private
model text and routing metadata are never exposed in status or SSE.

`ReadRunEngine.resumeSavedPlan` reloads this archive and revalidates its versioned
schema, entity scope, proposal, token limit and reserved model cost. It preserves
the original planning reservation when computing the answer budget and never
calls the planning model again. Current gateway policy still authorizes the read.
The caller must prove the previous worker stopped and provide the original task
and exact current checkpoint version. Only PLANNING with zero steps/calls and no
iteration or invocation can continue. Downtime is charged and CAS fences stale
controllers. If the recovery claim commits but loses its acknowledgement, reload
of the newer checkpoint permits another claim against the same older archive.

T14-RUN verifies one planning/read/answer sequence, retained cost, rejection of
corrupt reservation data and retry after a lost claim acknowledgement. T05-HTTP
checks archive persistence and revalidation through the live PostgreSQL engine.
This is an explicit host API; automatic execution recovery, post-proposal/tool
continuation and actual process-kill coverage at this boundary remain outstanding.
SQD-028 remains open.
