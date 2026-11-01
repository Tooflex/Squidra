# Durable internal movement watches (SQD-026)

`IntentionStore` is a host persistence port. `PostgresIntentionStore` binds one
authenticated actor; callers supply an owned entity and a bounded request key.
Models must not call it directly. The future `world.watch_entity` tool must pass
through the Action Gateway with an explicit capability and ledger (T13).

Registration stores an immutable entity/key binding and the actor's current
journal high-water mark. The same key/entity returns the original intention,
including its terminal state; changing the entity conflicts. At most 128 active
intentions are allowed per actor. Creating a new key after completion creates a
new watch. There is no implicit TTL or external notification subscription.

The watch is one-shot. The first eligible event delivered to it changes `active`
to `fulfilled`; later events do not produce another notification. `cancel` changes
only active intentions to `cancelled` and preserves terminal states. Registration,
cancellation, delivery and journal append share the same actor transaction lock.
A source must have committed after registration's high-water mark, so replaying
old history cannot immediately trigger a new watch.

Delivery accepts IDs, not a caller-supplied event payload. It loads the immutable
actor-scoped journal record, requires exactly the watched entity and the confirmed
movement type, then loads the source epoch. `MovementPublisher.validates`
recomputes the movement and compares the derived identity, complete payload,
source confidence and provenance. A forged event type, copied payload or invented
identity is insufficient. Missing/unqualified evidence creates no notification.

One SQL transaction appends `memory.watch_notified`, inserts the unique
intention/source receipt and fulfills the intention. An error rolls back all
three. Concurrent or repeated deliveries return the same journal notification ID;
only the winning call reports `created=true`. The notification contains its source
event and intention references, inferred basis and `channel=internal`. Its source
observation times/confidence are preserved, and its recorded time is assigned by
the journal. No external outbox entry, email, push or message is created.

Migration `world/004_watch_intentions.sql` adds scoped intention/receipt tables,
foreign keys and mutation guards. Bindings and terminal states cannot be rewritten;
notification receipts are immutable. Rollback may leave these records intact.
The small existing journal transaction/append helpers are internal to the
Postgres module to permit atomic notification composition, not new public APIs.

Run `bash Scripts/test-issue.sh SQD-026-SQL` through the isolated database helper.
It covers persistence through a fresh store/client, key conflicts, injected
transaction rollback, concurrent duplicate delivery, one-shot completion,
historical events, cancellation, forged evidence and actor isolation. The world
journal has exactly one notification and the external outbox remains empty.

`processNext` consumes one actor event in sequence order. Migration
`world/005_watch_dispatch.sql` stores a monotonic actor-scoped cursor. Notification
append, receipts, fulfilled states and cursor advance commit in one transaction;
a checkpoint failure rolls back all of them. Concurrent workers share the actor
lock. Internal notifications and unqualified events advance the cursor without
creating another notification. Empty journals perform no writes.

The live server owns a `WatchWorkerService` alongside its PostgreSQL client,
including when no model is configured. It polls idle journals every 250 ms,
advances the world projection after processing, and cancels and joins on shutdown.
Unexpected processing failures stop the service/application instead of silently
skipping an event. A fresh application resumes from the persisted cursor.

SQL tests inject checkpoint failure and verify atomic rollback, concurrent
processing, cursor draining and actor isolation. T05-HTTP exercises automatic
notification creation and a fresh live application with no duplicate delivery.
`bash Scripts/test-issue.sh SQD-026` is the complete acceptance gate: real
PostgreSQL transactions, live server lifecycle, and process restart. The opt-in
`squidra-watch-crash-fixture` runs only with isolated test database credentials.
Its parent script owns and kills its child PID with SIGKILL after either source
publication (pending notification) or committed notification/checkpoint. A fresh
process reads the actor/watch identity from an atomic marker and all remaining
state from PostgreSQL, drains the journal, verifies one stable notification,
replays the source without duplication, and checks the external outbox is empty.
A jitter epoch produces no movement and leaves the watch active before either
crash scenario. The marker contains no credentials or observation payloads.

The process fixture qualifies the durable dispatcher port; T05-HTTP separately
qualifies live application ownership and graceful shutdown/restart. It does not
claim a hardware power-loss test or an external sensor benchmark. The model-facing
Action Gateway tool remains T13 (#49); no direct model access to this store is
introduced. No new migration or production behavior is required by the crash
qualification itself. Rollback can remove the fixture and gates without touching
persisted intentions, notifications or cursors.
