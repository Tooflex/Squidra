# Data lifecycle — T12

## Verified backup profile

`bash Scripts/backup.sh CONTAINER NEW_ARCHIVE` creates a private (0600)
PostgreSQL custom archive of database `squidra` in a running local container
labeled `io.squidra.database=test` or `development`. It pins the inspected
container ID for subsequent operations, uses that container's PostgreSQL
utilities, and never publishes credentials. The archive is written to a private
sibling, fsynced, then published atomically without replacing any existing path.
Keep its parent directory private and controlled by the operator.

`bash Scripts/restore.sh CONTAINER ARCHIVE` accepts a private, owned regular
archive (no symlink/hardlink) and restores into a newly generated
`squidra_restore_<uuid>` database using template0 and a single transaction.
It prints that database name. It never replaces `squidra` or selects an existing
database supplied by the caller. PostgreSQL roles and ACLs are not restored;
this is a local same-role development/recovery verification profile. Matching
PostgreSQL 17, PostGIS and pgvector extension binaries must already be installed
in the destination image. It is not a production failover or role backup.

A dump is a full administrative database backup, **not an actor export**. It
contains sensitive stored application data from all actors. Store it privately;
encryption, off-machine storage, retention and a managed encryption-key policy
remain operator responsibilities. Only restore a trusted archive: PostgreSQL
archives can execute SQL. This utility does not sandbox hostile archives.
Neither command is exposed as a model tool or HTTP endpoint.

On restore failure, inspect the returned generated database name. The utility
leaves it for diagnosis, does not retry, and does not drop a database after an
uncertain timeout. An interrupted restore may still have a server-side session;
verify it has stopped before operator cleanup. A successful single-transaction
restore recreates journal triggers, facts, schema migration checksums and
projection versions. It does not promote the recovered database to production.

## Observed verification — 1 November 2026

`SQUIDRA_CONTAINER_ENGINE="$PWD/Scripts/colima-test-engine.py" bash Scripts/test-issue.sh T12-BACKUP`
passed all five checks against the PostgreSQL 17 Linux container on the macOS
controller: private no-overwrite archive; exact restored contents across nine
world/runtime/schema tables; stream version 2 and run version 7; immutable
journal and terminal-run protections; private-file/corrupt-archive checks;
rejection of an unrelated container. The original database remained unchanged.
All fixture containers were removed after verification. This qualifies the
local database recovery profile only.

## Remaining T12 work

Backup/restore and opt-in media retention are implemented below. Actor-scoped
structural export is described below too. Comprehensive personal-data erasure,
its privacy-policy acceptance, and deletion reconciliation after restoration
remain outstanding. The immutable journal must not be silently rewritten. If
export or deletion is later exposed as a tool, route it through gateway
authorization and approval. T12 is not complete yet.

## Opt-in retained media

`PostgresMediaRetention(actorID:client:)` adds an explicit trusted-host API.
It is not wired into existing imports, HTTP routes, or model tools. The host
must obtain actor identity from authentication, validate image content before
storage, supply trusted UTC microseconds, and schedule `purge` calls. The store
treats bounded bytes as opaque; an `image/png` label is not a decoder result.

`MediaRetentionPolicy(seconds:)` defaults to 60 seconds and accepts 1–3600.
`retain` accepts 1–65536 bytes and PNG/JPEG labels, refuses more than 128 live
blobs per actor, and permits only exact idempotent retries. `load` returns nil
for an unknown or foreign reference, and explicit `expired`/`erased` with no
bytes for an unavailable one. At the expiry boundary bytes are withheld even
before purge; a purge invocation transactionally clears at most 128 due blobs.
`erase` clears one authorized actor/frame blob early. Database triggers reject
reference deletion, metadata changes, or resurrection after unavailability.
Transaction cancellation/deadline handling uses the existing bounded PostgreSQL
repository, with deadlines no farther than five seconds. Caller cancellation
and uncertain outcomes require reading the reference before retrying.

These operations do not alter immutable journal events or erase personal data
elsewhere. SQL removal is not physical erasure from WAL, storage, or historical
backups. Review the explicitly proposed [privacy ADR](adr/0011-data-lifecycle.md)
for remaining decisions. The full T12 acceptance is still outstanding.

### Retained-media verification — 1 November 2026

`T12-MEDIA` passed five Swift tests against actual PostgreSQL: policy bounds,
exact byte round trip, actor isolation, half-open expiry, transactional purge,
erasure, immutable-reference constraints, conflicting retries, two concurrent
admissions for one remaining slot, capacity release, maximum 64 KiB payload,
and deadline/time-bound rejection. `T12-BACKUP` then passed all five checks with
available media and an unavailable reference included in its exact ten-table
restore comparison. The strict gates recorded no skipped or unexecuted tests.
Hosted CI remains suspended; the new gates are registered for Linux on its
restoration and in the corresponding local database gate list.

## Actor-scoped structural export

`PostgresStructuralExport(actorID:client:).page(cursor:limit:deadline:)` is a
trusted-host, read-only API for the explicit `journal-structure` scope. It has
no HTTP route or model tool. The host supplies the authenticated actor and
checks authorization. The Codable cursor is a pagination value, not a signed
authorization token; decoding it does not establish ownership.

Version 1 exports event UUID, sequence, stream UUID/version, observed UTC
microseconds and payload version, plus associated fact UUIDs, provenance event,
subject/object/frame UUIDs, validity microseconds and confidence. It deliberately
omits labels, entity kinds, event type, source strings, arbitrary predicates,
payload JSON, observation bodies, runtime prompts/checkpoints, raw media and
provider configuration. It also excludes unreferenced entities, media and
runtime records. This is a structural evidence export, not a full database
backup, a full account export or a legal portability claim. Identifiers and
times may still be personal data: disclose them only to the authorized actor.

Each page selects 1–64 events and at most 128 associated facts. Too many facts
cause an explicit failure, never silent truncation. The first page records the
actor's committed journal high-water sequence; subsequent pages reuse it so
later appends are excluded. All queries and cursors bind to the actor. Qualified
journal appends serialize per actor, as required by the existing repository.
Each page uses a read-only repeatable-read transaction; mutable projections
may change between pages, so this does not claim a multi-page database snapshot.
Use the administrative backup for a whole-database recovery snapshot instead.

Unknown/empty actors yield an empty page. Invalid limits, foreign or malformed
cursors and deadlines fail. Every returned scalar comes from an explicit typed
column allowlist; a free-text canary must never appear in encoded output.
The export does not modify source records or waive the remaining erasure work.

### Export verification — 1 November 2026

`T12-EXPORT` passed five tests against actual PostgreSQL: actor-scoped output
without seeded secret canaries or foreign identifiers; unchanged journal bytes;
pagination with a later append excluded from the captured high-water range;
invalid decoded/foreign cursor and limit/deadline rejection; failure on 129
associated facts; empty-actor and 64+1 event page boundaries. No tests were
skipped. The media gate is also rerun whenever its shared harness changes.
