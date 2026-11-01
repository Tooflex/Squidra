# World watch gateway contract (T13)

`WorldWatchTool` exposes `world.watch_entity@1.0.0` through `ActionGateway`.
The host supplies an actor-bound `IntentionStore`, a bounded entity target grant,
the `world.watch.create` capability, the `world:watch` scope and an `ActionLedger`
backed by PostgreSQL. The tool is R1 (`durableLedger`): creating the local watch
is reversible by cancelling its active intention. There is no external delivery.
No model adapter receives the store, client, SQL or an execution grant.

Input is a closed object containing `schemaVersion: "1"`, `entityId` and
`filter: "confirmed_movement"`. It cannot choose an actor, channel, arbitrary
filter, SQL, callback or notification recipient. The target is independently
resolved from the entity UUID and compared with the authorized target. The
adapter checks its host actor and required scope before accessing persistence.
The store's actor/entity foreign key prevents a foreign entity from being watched.

The gateway owns the idempotency key. The adapter hashes its full bounded value
with SHA-256 under a versioned tool prefix to fit the intention key limit without
truncation. The ledger binds the actor, tool, target, arguments and scopes;
changing an entity under the same key conflicts. Successful replay uses the
persisted original result and creates no new intention, including across new
store/gateway instances and after host cancellation. A replay is a historical
receipt, not a read of the current intention state.

The strict output contains actor/entity/intention IDs, the registration status,
confirmed-movement filter, internal channel and journal high-water mark. It does
not claim that movement happened or that a notification was delivered. Actual
notifications preserve source event/epoch evidence in the journal (SQD-026).
The two R0 read tools retain their fact/change evidence references.

The ledger and intention store commit separately. If a process dies after the
intention commits but before ledger completion, pending/unknown ledger results
remain unconfirmed and require the existing host reconciliation flow. The
gateway never silently redispatches an uncertain mutation. The intention's
unique actor/key binding also prevents duplicate registration. No automatic
reconciliation or model-facing cancellation tool is introduced by T13.

Run `bash Scripts/test-issue.sh T13` for location/change/watch schema contracts
and actual PostgreSQL gateway integration. Tests cover missing policy/ledger,
foreign actor/scope, injected input authority, durable replay, changed-entity key
conflict, host cancellation and output schema copies. `T13-READS` remains the
legacy database helper name and now includes the watch integration test.

This adds a dependency on the existing Memory port, not a database dependency to
Tools. There is no migration. Rollback removes the tool registration/contract;
existing intentions and receipts remain intact. The read-only text planner does
not gain mutation authority merely because this tool exists.
