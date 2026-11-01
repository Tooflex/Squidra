# ADR-011: Data lifecycle and privacy boundaries

Status: **Proposed — privacy policy requires maintainer acceptance.** The
retained-media implementation can be reviewed independently; merging that code
does not constitute acceptance of a comprehensive personal-data erasure policy.

## Context

T12 (#48) requires short media retention, explicit unavailable references,
actor-scoped exports, and erasure by anonymization/tombstones without silently
rewriting the immutable journal. Current imports persist derived observations,
not the uploaded raw image. The journal permits application JSON and entity
labels; these may contain personal data. Calling a tombstone “physical erasure”
would therefore be inaccurate.

## Proposed decisions

1. Raw images remain unretained by default. A trusted host may opt into the
   PostgreSQL media store, with a default 60-second lifetime and configurable
   range 1–3600 seconds. Each blob is at most 64 KiB, with at most 128 live blobs
   per actor through the adapter. Reject capacity exhaustion, never evict an
   unrelated actor. The host supplies authenticated actor identity and trusted
   wall-clock microseconds, and schedules bounded purge calls.
2. Media bytes and their reference state live in one database transaction.
   Expiry blocks reads immediately at the inclusive expiry boundary, even if
   purge has not run. Purge removes the SQL bytea and marks the retained
   reference `expired`; authorized early removal marks `erased`. Identifiers,
   capture time, expiry, type, and original byte count remain immutable.
   Neither operation rewrites world events. No retry can resurrect a reference.
3. A retained reference is an operational tombstone, not an assertion of
   physical disk erasure. PostgreSQL MVCC, WAL, replicas and existing backups
   may retain prior bytes. Administrative backups contain all actors and need
   their own approved retention/access policy. Restoring an older backup must
   apply the latest deletion decisions before exposing recovered data; this
   reconciliation is not yet implemented and must not be claimed complete.
4. Export is a separate authenticated, bounded read operation. It must use an
   explicit allowlist of fields, omit raw payloads, prompts, credentials and
   unrestricted labels, and bind every query/cursor to the actor. General JSON
   redaction is not sufficient. A backup is never an actor export.
5. Personal-data erasure beyond retained media requires a defined subject
   scope and consistent suppression across query/projection/recovery/export
   paths. Tombstones alone do not remove existing journal payloads. Before
   promising physical erasure, choose and implement a compatible strategy
   (for example, segregated encrypted personal payloads with managed key
   destruction and backup handling). No such guarantee exists in this revision.
6. No lifecycle operation is exposed as a model tool or HTTP endpoint here.
   Any later exposure must use the gateway's actor authorization and applicable
   approval, with no direct model selection of an actor or arbitrary SQL.

## Consequences and outstanding acceptance

Transactional byte removal avoids a filesystem/database split failure, but
puts bounded image bytes into administrative backups. The immutable reference
can still be identifying metadata and is not anonymized. The retention adapter
is opt-in and cannot establish a deployment-wide retention guarantee unless its
purge scheduler and clock are operated correctly.

The maintainer still needs to accept the privacy policy, especially personal
subject scope, journal treatment, backup retention and restoration reconciliation.
Prepare the scoped export and erasure integration before requesting final T12
acceptance. T12 remains open until its actual requirements are verified; this
ADR does not waive them.
