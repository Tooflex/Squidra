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

This change supplies the transactional store and explicit delivery operation.
A bounded journal dispatcher, application lifecycle activation, gateway tool and
process-restart qualification remain separate work. SQD-026 stays open until the
watch is actually driven across replay/restart; calling the store directly is not
claimed to be a running background monitor.
