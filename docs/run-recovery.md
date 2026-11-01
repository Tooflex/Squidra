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
PostgreSQL/process-crash boundary qualification, host activation and end-to-end
resumption are still pending. This document does not claim the full issue complete.
