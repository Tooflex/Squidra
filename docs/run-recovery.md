# Run recovery

## Current qualification entry point

Run `bash Scripts/test-issue.sh SQD-028` for the aggregate recovery check.
It executes checkpoint unit tests, approval wait contracts, PostgreSQL effect
reconciliation, actual effect and approval process crashes, local ownership, normal CLI
publication recovery, automatic read-host process crashes, and HTTP status
regressions. Each child must pass its own nonzero-test validation before the
aggregate reports its marker; failure preserves the child exit code.

Automatic startup continuation is implemented for persisted read tasks when the
host has a read configuration and holds the actor's local ownership lock. The
normal model-free CLI can recover completed publication archives. Generic
`RunRecovery` and `ApprovalWait` remain explicit host operations; the automatic
read host does not execute effectful tasks or resume approval workflows.
The sections below record successive implementation stages; earlier statements
that host activation or approval crash qualification is pending are superseded by
the automatic read-host and approval process-death sections. This gate does not
claim real-provider, Linux or cross-host failover qualification.

The SQD-028 acceptance scope is the implemented automatic read host and explicit
trusted-host recovery APIs. An unknown external effect deliberately terminates
with RECOVERY_REQUIRED when no authoritative verifier can establish its outcome;
it is not retried. Automatic execution of arbitrary effectful tasks is not an
implicit capability of checkpoint restoration.

| Requirement | Implementation and executable evidence |
| --- | --- |
| Reload checkpoints and approvals | RunRecovery / ApprovalWait; SQD-028-UNIT, SQD-009 and six actual approval process-crash scenarios |
| Reconcile pending/unknown actions before retry | Exact actor/run/key/fingerprint binding, authoritative RunEffectVerifier, persisted ledger result; SQD-028-DURABLE and reserved/pending/effect/result process crashes |
| Explicitly stop when a remote effect is unverifiable | FAILED / RECOVERY_REQUIRED with no new dispatch; pending process-crash and checkpoint tests |
| Resume without duplicating effects | Confirmed receipts/results reused; reserved work claims its original key; one or zero effects asserted in independent processes |
| Consistent status and correlation | Preserved budgets, trace/run IDs, monotonic versions; automatic host recovery and HTTP/SSE status/replay checks |

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

## Saved-plan recovery across process death

`SQD-028-SAVED-PLAN-CRASH` runs the real read engine until its validated plan has
committed in PostgreSQL, then the separate test-only plan-store wrapper signals
the harness and waits. The harness SIGKILLs that owned process and verifies its
exit before a new process reloads the original task and checkpoint. No production
crash hooks are used. At this boundary there has been one planning model call and
zero tool calls or steps.

The fresh process calls `resumeSavedPlan` with a fixture model that can only emit
one final answer, so repeating planning cannot pass. It requires the original
checkpoint budget, nondecreasing consumed time, one read/step, the retained
planning reservation of 5 microUSD and total reservation of 10 microUSD. The real
engine can reduce the initial active budget by admission time before creating its
checkpoint; the test compares the complete persisted budget rather than assuming
an exact 15 seconds. Costs here are authored fixture values, not billed usage.

The normal model-free server subsequently publishes the completed archive after
natural lease expiry. A second server process must replay the identical six SSE
frames; the database verifier checks terminal runtime version and counters plus
archived/published answer equality. The suite is registered in local checks and
the currently suspended Bootstrap workflow. This qualifies the explicit saved
plan continuation; automatic execution recovery and later-phase continuation
remain pending for SQD-028.

## Durable read-tool result before acknowledgement

The live read engine saves the gateway's untrusted tool result before committing
`finishToolAttempt(.confirmed)` and before asking the model for an answer.
`ReadRunToolResultStore` retains the original call UUID, tool identifier, command
fingerprint and bounded raw JSON with actor/run/request and execution checkpoint
version. It is private run data, not a new factual proof or a dispatch grant.
Evidence still passes through `WorldReadEvidenceDecoder` and final grounding.

Migration `runtime/008_read_run_tool_results.sql` makes the archive immutable and
binds it to the runtime and saved task. The PostgreSQL insertion checks the exact
EXECUTING_TOOL version, one step/call, matching task request and command digest,
and the original in-flight invocation key with one attempt. Only the two bounded
world read tools are accepted. An exact duplicate save is idempotent even after
later FSM progress; conflicting bytes or metadata fail. Actor-scoped loads retain
the raw bytes. Purging follows the containing task/run lifecycle.

A failed or ambiguously acknowledged archive write returns recoveryRequired,
leaves the execution checkpoint intact and performs no answer-model call. The
result can therefore be reconciled later without recreating the read. Missing
archives do not establish whether the read happened. This step adds durable input
for later-phase recovery; it does not yet activate result-based continuation or
an automatic execution takeover.

T14-RUN covers successful archival and loss of its acknowledgement, checking one
read, unchanged checkpoint on failure and no premature answer. T05-HTTP checks
real live persistence, ordering between planning and completion archives, exact
command binding, schema/evidence decoding, actor isolation and SQL update
rejection. SQD-028 remains open until continuation and host activation are complete.

## Continue from a saved read result

`ReadRunEngine.resumeSavedToolResult` now continues an interrupted read after the
host proves the previous worker stopped and reloads the original task. It loads
both planning and tool archives, checks actor/run/request identity and checkpoint
ordering, revalidates the plan against the supplied scope and model limits, and
recomputes the exact original command fingerprint and invocation key. Tool bytes
must pass catalog schema and actor/entity/time/evidence validation before any
checkpoint changes. Catalog reconstruction remains untrusted data; it is not a
new gateway grant and does not dispatch a tool.

The runtime accepts only EXECUTING_TOOL with the exact inspected version, one
step/call/attempt, matching iteration digest and invocation key. An in-flight
attempt with no recorded outcome or an already-confirmed attempt is eligible.
The durable claim reconciles it to confirmed, charges downtime, retains the
original budgets and increments the version. A lost claim acknowledgement can
be retried only after reloading the newer version. The continuation then uses the
ordinary evidence/answer/grounding/completion path without planning or reading
again, and retains the original planning cost reservation. It does not resave or
replace the original result archive or original call UUID.

RESPONDING is explicitly excluded: an answer model may already have started and
its cost/outcome cannot be inferred from a read result. Missing, corrupt, foreign,
stale or mismatched inputs grant no continuation. Expired runs become TIMED_OUT
without another read/model call. Automatic host execution recovery and durable
answer-phase continuation remain outstanding; SQD-028 is still open.

T14-RUN covers lost archive, confirmation and recovery-claim acknowledgements,
exact budget/cost preservation, one read across continuation, terminal and
responding refusal, missing/corrupt archives, stale versions and expiry.
`SQD-028-SAVED-RESULT-CRASH` kills the owned seed process after PostgreSQL commits
the real tool result. A fresh process reloads the task and invokes this API with
an answer-only fixture model, then normal model-free servers recover and replay
the identical six-event stream. The fixture keeps one step/call and the original
checkpoint budget with the authored 5+5 microUSD reservations. No production
crash hooks or new migration are added by this continuation.

## Answer-model archive and cost reservation

The live engine now also persists `ReadRunAnswerStore` after the model response
passes `GroundedAnswerValidator`, before saving the published grounded answer or
finishing the iteration. `ReadAnswerArchive` retains response request/model IDs,
model version, exact response text, output tokens, monetary amount and its evidence, attempted models
and the reserved upper bound. Its versioned codec bounds text to 32 KiB and the
whole archive to 64 KiB, rejects unknown/noncanonical fields, NULs and impossible
cost metadata, and reconstructs only an ordinary untrusted model response.
Decoding does not replace evidence validation or mint a GroundedAnswer.

Plan and answer archive writers now emit version 2 with `costBasis` and an
optional `costRateID`. Version 1 remains readable with unspecified monetary
provenance; it is never promoted to a provider-reported charge. Rate estimates
remain estimates after restart. Version 2 is not readable by older binaries:
retain these archives for a compatible reader when rolling back, without
rewriting them or replaying an already completed provider attempt.

Migration `runtime/009_read_run_answers.sql` binds the immutable archive to the
actor/run, saved task and saved read result. Insertion requires the exact
RESPONDING version, one step/call and matching task request. Identical save retries
remain valid after later runtime progress; conflicting metadata/bytes fail.
Loads are actor scoped and the archive follows the private run-data purge
lifecycle. Model text is not exposed through status, SSE or tracing.

An archive failure or lost acknowledgement returns recoveryRequired with the
responding checkpoint intact, two total model calls and one read; no completion
archive or terminal success is written. Invalid grounded responses are never
archived. T14-RUN covers this boundary, exact retained model/cost data and rejection
of malformed archive metadata. T05-HTTP loads the live PostgreSQL archive,
reconstructs the response, validates it again against the saved read evidence,
and checks request/version binding, actor isolation and SQL update rejection.

This stores the missing recovery inputs; it does not yet continue RESPONDING.
Continuation must preserve both planning and answer reservations, validate saved
scope/evidence, and handle an already-existing grounded completion without
silently replacing its original observation-age metadata. Automatic host recovery
and qualification of this later boundary remain pending for SQD-028.

## Finish a saved answer without model or tool calls

`ReadRunEngine.resumeSavedAnswer` now reloads planning, read-result and answer
archives for the original task after the host proves the old worker stopped.
It validates actor/run/request identity, archive version ordering, scope, command
fingerprint, tool schema, scoped evidence and answer grounding. Both model
reservations must fit the original total budget, including token limits. No
planning, tool dispatch or answer-model call occurs during this operation.

The exact inspected checkpoint must be RESPONDING with one step/call and a
confirmed matching invocation. If finishIteration already committed but lost its
acknowledgement, its cleared iteration is eligible only when a grounded completion
archive exists. The durable claim charges downtime, preserves budgets and fences
older versions. Lost claims can be retried only after reloading the newer version.
Expired work becomes TIMED_OUT without a new completion or model/tool call.

If no completion exists, the revalidated answer is saved once. If it already
exists, the trusted completion store's actor/run/request/version binding and JSON
envelope are checked and its exact bytes are retained. That store only accepts a
host-grounded value on save; the recovery path does not decode raw bytes into a new
GroundedAnswer. Revalidating the saved response still checks current evidence
policy, but does not overwrite original observation ages or text in an existing
completion. The operation returns `RecoveredReadRunCompletion` (runtime snapshot
and both model reservations); publication uses the original durable archive.

T14-RUN covers ambiguous answer/completion writes, iteration completion and
recovery claims, retained budget/cost, zero additional calls, byte-identical
existing completion, terminal refusal, corrupt/missing/mismatched answer data,
stale versions and expiry. `SQD-028-SAVED-ANSWER-CRASH` and
`SQD-028-SAVED-COMPLETION-CRASH` SIGKILL the owned worker immediately after the
respective real PostgreSQL commit. A fresh process completes with zero model
calls, then normal model-free servers publish and replay the same six events.
The completion case additionally compares exact bytes and original archive
version across recovery. These fixture hooks remain outside production code.

These APIs now cover the persisted plan, read and answer boundaries. Automatic
server execution recovery still needs durable worker ownership and activation;
unknown outcomes without their required archives must not be retried implicitly.
SQD-028 remains open for that integration and its qualification.

## Local worker ownership primitive

`LocalRunOwnership` provides a nonblocking exclusive kernel lock for one actor in
an existing private local directory. The host must retain the handle until all
workers stop and join, including cancellation, then call
`releaseAfterJoiningWorkers`. Destruction closes the descriptor as a fallback;
O_CLOEXEC prevents an executed child from retaining it. The lock file is never
unlinked on release. A subsequent owner reads its stable random domain UUID and
obtains a new owner UUID.

Recovery registration must persist and compare **both** domainID and fileID
(device/inode), as well as actor identity. Copying a file preserves its contents
but does not prove that a process holding the original inode has stopped. A
replacement/copy therefore cannot authorize recovery of the old owner's runs.
Admission must also bind the actor to that local domain before dispatch; merely
constructing a handle is not sufficient authorization to resume arbitrary runs.

The primitive opens a private owner-only directory, then opens the lock relative
to its descriptor with no-follow and close-on-exec. It rejects symlinks, shared
permissions, nonregular files, hard links, malformed identities and unsupported
filesystems. Identity initialization is synchronized and fsynced while locked.
Darwin requires MNT_LOCAL; Linux permits an explicit set of local filesystem
types. This is an offline same-host mechanism, not a distributed lease or a claim
that a lost PostgreSQL connection proves process death. It must not be used for
cross-host database deployments or copied runtime-directory failover.

`SQD-028-OWNERSHIP` covers same-actor exclusion, independent actors, stable identity
across release, copied-file distinction and unsafe-path rejection. It also starts
an owned Python child holding the same kernel lock, verifies contention, SIGKILLs
that exact child, waits for confirmed signal exit and reacquires the unchanged
identity. Python is test-only. Local macOS qualification passes; Linux still needs
its configured CI qualification when hosted CI is restored.

The primitive is wired into explicit server admission as described below.
Automatic startup continuation remains necessary before SQD-028 can close.

## Durable actor and run owner registration

Migration `runtime/010_read_run_ownership.sql` adds the actor's immutable local
(domain UUID, device/inode) binding and an immutable owner UUID for each admitted
run. The actor binding outlives run retention and rejects updates, deletion and
truncation: losing or copying the runtime directory must not silently reset it.
Run-owner rows follow task retention and reference both the saved task and exact
actor domain/file identity. An explicit separately designed migration is required
to move that domain; the runtime never infers takeover authority from a mismatch.

`PostgresReadRunOwnershipStore` retains the live local lock handle and refuses
operations after release. Registration binds the actor, then inserts only against
an unexpired unmanaged stream, holding a shared row lock so a publication claim
cannot overtake it. An exact retry remains valid after publication has started;
replacing an existing owner fails. `previousRuns` returns at most eight retained
running streams registered to a different owner in the same actor/domain/file.
It excludes the current owner, terminal streams and untracked legacy runs.
Selection alone is not an execution or publication claim.

`PublishedReadRunCoordinator` accepts this registration port between task save
and publication claim, before worker dispatch. Any failure dispatches nothing.
An explicitly supplied `localOwnership` in `ServerComposition.live` is checked
against the actor, bound before serving, passed to admission and retained by
`ReadWorkerService`. Graceful shutdown joins the coordinator's pending admissions,
workers and publication cleanup before releasing the handle. The existing
model-free/status-only composition requires no ownership lock.

T05-WORKERS checks real registration before execution, exact retry after claim,
rejection of a copied identity without dispatch, released-handle rejection,
previous-owner selection after joined shutdown, untracked-run exclusion and SQL
immutability. T05-HTTP verifies the live admission row and lock release after
service shutdown. T03 verifies the migration with runtime constraints.

CLI ownership configuration and completed publication recovery are described below.
SQD-028 remains open for automatic nonterminal continuation and its complete
process-crash qualification.

## Publication takeover under held local ownership

`PostgresRunPublicationStore.takeOver` transfers a running publication to the
new local owner only when the durable registration matches the held actor/domain/
file identity and belongs to another process. It locks the stream and changes only
`execution_owner`. The lease and returned execution deadline (lease minus the
original five-second publication grace) remain unchanged. An already exhausted
execution deadline, unmanaged/terminal stream, copied file, original registering
owner or untracked run cannot obtain a claim.

The new owner's UUID also fences a second claim in the same process. If the commit
acknowledgement is lost, that process must not dispatch based on a retry; a later
process can reconcile under the same local lock. The returned opaque capability
retains the lock handle and refuses publication after release. The old claim is
fenced by its mismatching database owner. Hosts must keep the lock until every
resumed worker and publication operation has joined, as for normal admission.

T05-WORKERS exercises transfer before lease expiry, exact original deadline over
two owner transitions, old/repeated/released claim rejection, invalid ownership,
untracked and terminal streams, and refusal during publication grace after the
execution budget expires. This is the publication primitive; automatic selection,
checkpoint continuation and archived-completion finalization are not activated by
this change. No model or tool is dispatched by takeover.

## Completed archives under local ownership

`PostgresRunPublicationStore.recoverCompleted` finalizes a registered previous
owner's completed archive while the same actor/domain/file lock is held. Unlike
execution takeover, it needs no remaining execution budget: the runtime must
already be `COMPLETED` with a newer version than the immutable completion archive.
It checks the original saved task, request, thread, intent and subjects through the
same archive validator used by expired-lease recovery. No model, tool, runtime
transition or lease renewal occurs.

The stream row lock serializes concurrent finalizers; one appends the five terminal
frames and subsequent attempts return false. The existing started frame remains.
A missing completion or unfinished runtime returns false without publishing.
A current registering owner, copied domain file or released handle is rejected.
Retention expiry still forbids publication. The internal stopped-owner append
permission is reached only after the local registration proof; normal owner
publication still requires its live lease, and the existing model-free background
recovery still requires lease expiry.

T05-HTTP covers owned finalization before and after lease expiry, concurrent
single publication, unchanged complete runtime snapshots, incomplete runtime
refusal, copied/current/released ownership refusal, HTTP/SSE archive equality and
replay across two server lifetimes. Automatic local startup continuation is still
to be wired with a lifecycle that joins recovery and execution before releasing
the ownership handle.

## Automatic completed publication and joined ownership lifetime

When `ServerComposition.live` receives explicit local ownership, its recovery
loop selects at most eight previous-owner completed runs and publishes an archive
without waiting for lease expiry. Selection filters completed runs before applying
the limit, so interrupted nonterminal runs cannot hide eligible completions.
The existing expired-lease recovery remains available after the owned pass.
Model-free composition can now accept the lock for this publication-only path.

`ReadWorkerService` owns both the recovery loop and optional submission
coordinator. Graceful shutdown, task cancellation and recovery errors join the
recovery child task, then shut down and join the coordinator, and only then release
the local handle. The database service stays alive during that cleanup. Servers
without local ownership or a submission coordinator retain the separate
publication-only service.

T05-HTTP exercises automatic owned recovery before lease expiry through live
model-free composition, subsequent SSE replay and lock release on graceful stop.
A cancellation test holds recovery cleanup beyond cancellation and verifies the
lock stays held until that cleanup joins. Existing worker shutdown and cancellation
checks remain in the same suite. Automatic continuation of nonterminal checkpoints
still remains to complete SQD-028.

Concurrent startup binding uses untargeted `ON CONFLICT DO NOTHING`, followed by
an exact domain/file comparison. Both the actor primary key and the composite
foreign-key target are unique; targeting only the primary key can let concurrent
identical inserts fail on the other index. T05-WORKERS exercises two clients
binding the same held owner, and retains the copied-domain rejection checks.

## CLI ownership directory and real process recovery

Set `SQUIDRA_RUN_DIRECTORY` to an existing absolute local directory owned by the
server user with mode `0700`. For example, create a persistent directory once with
`mkdir -m 700 /absolute/path/to/squidra-runs`, then provide its path in the server
environment. `squidra serve` acquires the actor lock before starting services and
passes it to the live composition. Without this variable, the existing model-free
server and expired-lease recovery remain available.

The CLI does not create or replace that directory. Keep its lock files across
restarts: deleting or copying them cannot transfer the durable database ownership
binding. A simultaneous server for the same actor/file, an unsafe directory,
symlink or missing directory fails with the generic redacted startup error.
`check-config` validates the path syntax without creating files or acquiring a
lock; filesystem and exclusivity checks occur when serving. Relative, empty and
NUL-containing paths are invalid. No configured path is printed on failure.

`SQD-028-OWNED-PUBLICATION-CRASH` starts a real fixture that acquires this lock,
registers its saved task and completes a run under a 185-second publication lease.
The harness SIGKILLs that exact child, starts the normal model-free CLI with the
same directory and verifies six SSE frames before that lease can expire. A second
live CLI is refused. It then SIGKILLs the first server and verifies byte-identical
replay from another CLI, which exits cleanly on SIGTERM. Runtime version, one tool
call and the original archived answer are checked by a separate process.
The harness also checks configuration-only operation and unsafe paths. Other
crash suites retain their original expired-lease behavior; this suite explicitly
proves recovery through the local ownership path. It does not yet resume
nonterminal runs or configure a CLI model host.

## Automatic nonterminal read continuation with an explicit model host

A live composition with both `readHost` and local ownership polls registered
previous-owner runs after completed-archive recovery. It loads the immutable task
and current runtime version, then reserves capacity in `PublishedReadRunCoordinator`
before acquiring publication takeover. Recovery shares the coordinator's admission
limit, cancellation endpoint and joined shutdown. A failed or ambiguous claim
never dispatches; a repeated candidate already reserved by this host does nothing.

The host chooses the existing checked engine continuation by checkpoint:
CREATED/VALIDATING/CONTEXT_LOADING resumes before planning; PLANNING requires its
saved plan; EXECUTING_TOOL requires its saved read result; RESPONDING requires its
saved answer. The engine retains the runtime version fence, original budgets,
idempotency key and downtime accounting. Unsupported states, missing archives or
a saved scope outside the current host's allowed entities fail closed with public
recovery-required status. Global scope is not admitted by this host path.

The coordinator additionally caps the worker by the earlier of the saved request
and original publication deadlines. Successful execution publishes through the
checked completed archive, never reconstructing a new proof from untrusted bytes.
Completion cleanup is joined; an uncertain publication leaves durable recovery
state for the archive poller. No HTTP status/replay request dispatches execution.

T05-HTTP exercises real early checkpoint continuation through live composition
(two model calls, one read, preserved run/trace/budget), missing-plan and revoked-
scope refusal with zero model calls, and cancellation during the resumed model
call. T05-WORKERS checks that a pending recovery claim consumes shared capacity and
that shutdown joins its cancellation without execution. Saved-plan/result/answer
engine crash suites remain separate qualification; full automatic process-crash
coverage of these host routes and CLI model-host configuration remain outstanding.

Resumed execution creates a private trace with the original trace/run/request
correlation. Actual model and tool calls inherit it; archived work is not reported
as new calls. The live continuation test checks one run span, the expected model
span count and original trace ID in all four scenarios, with no saved question
text in the HTTP trace response.

## Candidate progress and admission before the first checkpoint

Continuation selection applies eligibility before its bounded limit: the stream
must still have execution time left, must not already be claimed by this process,
and must not have a terminal runtime. Thus eight expired, already claimed or
terminal rows cannot hide a later eligible run. Completed selection requires the
completion archive and its runtime version relationship before limiting rows.
The unfiltered candidate API remains available for inspection; completed and
continuable filters cannot be requested together.

A registered admission can be interrupted after its publication claim but before
the engine creates its initial runtime. The live host handles `RunStoreError.notFound`
explicitly for this case. Under the proved stopped owner and transferred publication
claim, it starts the original task with the original IDs and remaining request/
publication deadline. This is first execution: the engine commits its initial
runtime before any model or read call. Other load errors do not authorize execution.
Current host scope and shared admission/cancellation checks still apply.

T05-WORKERS seeds eleven ordered runs: four exhausted, four already claimed by the
new owner, a completed runtime without an archive, an eligible admission and a
completed runtime with its archive. Limit-one selections find the eligible run and
archive, and a taken-over claim disappears from continuation selection. T05-HTTP
also covers an admission with no runtime through the live server: two model calls,
one read, original run/trace IDs, bounded budget and correlated trace.

## Automatic host continuation after real process crashes

`SQD-028-AUTOMATIC-HOST-CRASH` runs one XCTest with five process scenarios:
pre-planning, saved plan, saved read result, saved answer and saved completion.
For each, the existing fixture commits its boundary under local ownership and is
killed with SIGKILL. A new XCTest child runs the real `ServerComposition.live`
with its normal recovery loop, coordinator, PostgreSQL stores, gateway and routes.
It never calls a resume method directly. Authored model injection exists only in
the test target; the production CLI has no fixture-provider flag.

The resumed host must complete with the original runtime budget and trace ID,
one tool invocation and one iteration. Its actual new model calls must be
2/1/1/0/0 respectively, and traced tool calls 1/1/0/0/0. Persisted plan, result
(including call ID), answer and completion archives present at the crash boundary
must remain unchanged. The host exposes ready health and six SSE frames. The
harness then kills that host and starts another, checks an identical terminal
runtime and byte-identical SSE replay with zero new model calls, and requires
clean SIGTERM shutdown. Every child PID is owned by the test and joined; logs and
credentials stay in private temporary files/environment, with bounded redacted
child diagnostics only on failure.

This qualifies automatic host recovery for these five saved boundaries on the
executed platform. It does not qualify a real model provider, CLI model-host
configuration, cross-host failover or unknown remote effects. Linux process
qualification remains part of restored CI. Generic pending-action recovery is
qualified by the separate effect-crash tests, and approval restoration by the
process-death tests below. Neither enables automatic effectful startup execution.

## Approval waits after actual process death

`SQD-028-CRASH` now also runs six approval scenarios: pending, approved, denied,
withdrawn, pending past expiry, and approved past expiry. The fixture reserves the
exact command, persists an approval and the WAITING_APPROVAL checkpoint, optionally
persists a decision, then publishes its committed marker. The harness kills and
joins that owned process with SIGKILL before starting a fresh continuation process.

The new process checks the exact saved checkpoint, actor/run/trace, approval digest,
original expiry and command fingerprint. A pending wait remains unchanged until
an explicit fixture-owner decision. An unexpired approval resumes at VALIDATING /
POLICY_CHECK; it does not issue a tool permit. Denial/expiry becomes POLICY_DENIED,
withdrawal becomes CANCELLED. Expiry uses actual elapsed time and the original
PostgreSQL timestamp, including an approval that expires while its worker is dead.

Every scenario checks unchanged active budget, steps and zero calls; the action
must remain reserved with its original key and zero receipt effects. A second fresh
process verifies the persisted outcome and rejection of another restoration of
the old wait. These checks passed locally on macOS with isolated PostgreSQL;
the four existing action-crash scenarios also passed (11 runner checks including
the loopback boundary). This is explicit trusted-host continuation through the
production ApprovalWait API. Automatic startup of effectful tasks, arbitrary
remote-effect verification and cross-host failover are not enabled or claimed.

The first fixture used a ten-second I/O deadline, which the PostgreSQL ports
correctly rejected. It now uses a fresh four-second deadline for each operation;
the approval TTL and elapsed-time expiry wait are independent. Error diagnostics
expose only closed approval/run error codes, never SQL text or credentials.
