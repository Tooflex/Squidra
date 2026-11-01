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

The current frame import path retains derived observations, not raw uploaded
image blobs. Short configurable blob retention, explicit unavailable references,
actor-scoped export, and personal-data tombstones still require implementation
and a concrete privacy ADR. Backup verification alone does not complete T12.
The immutable journal must not be silently rewritten. If export or deletion is
later exposed as a tool, route it through gateway authorization and approval.
