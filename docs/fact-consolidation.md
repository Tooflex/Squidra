# Bounded fact consolidation

`FactConsolidation` provides an offline review workspace for SQD-029. A trusted
host supplies an actor's original `MemoryRecord` values and a catalogue of
single-valued predicates, including their criticality. An extractor supplies
untrusted `FactCandidate` values: subject, predicate, proposed value, valid-time
interval and exact quotations keyed by original memory ID. No model or source
text can change predicate criticality, grant scope or approve a proposal.

The workspace accepts at most 256 original records / 256 KiB of source text,
32 predicates, 32 candidates per atomic batch and 256 proposals/batches overall.
Candidates contain at most 16 quotations of 2048 bytes and a 2048-byte value.
Every quotation must occur in a supplied same-subject memory. Actor mismatch,
secret source records, unknown predicates, empty periods, fabricated quotations
and excessive bounds fail before changing state. At most 16 distinct original
source IDs are retained per proposal. The batch UUID is an idempotency key;
reusing it with different candidates fails. Repeating evidence never increases
a confidence score; no such inference or score exists here.

All differing values for the same subject and single-valued predicate whose
half-open valid times overlap are marked conflicted, including contradictions
with previous or rejected proposals. Equal values and adjacent periods do not
conflict. Conflict detection is deliberately structural: it does not infer
synonyms, entailment, causality or truth from a quotation. A supported quotation
may still be misinterpreted, so even noncritical proposals require review.

A host-authenticated reviewer can approve or reject only the exact pending
proposal version. Review metadata is retained. Conflicts cannot be waived by
review; new contradicting evidence marks even an approved proposal conflicted
and prevents future exports. The review call is a trusted application boundary,
not a public authentication mechanism or a tool permission. The HTTP review
below supplies the owner authentication boundary. Any downstream tool use must
still pass the existing exact-command approval gateway; a fact review grants no
external action permission.

Promotion produces a `privateOnly` MemoryRecord retaining the original source
IDs and validity period. It is not world-tool evidence and cannot enter the
model-visible memory query. Export checks current state each time. Previously
returned copies cannot be recalled; downstream persistence must check current
proposal state before reuse rather than treating exports as perpetual proofs.
Original memory records are immutable and remain inspectable; there is no world
journal write/delete capability, external publisher or destructive operation.

`bash Scripts/test-issue.sh SQD-029` verifies seven scenarios spanning citation
and actor isolation, atomic failures, changed idempotency keys, exact reviews,
rejection, critical proposals, overlapping and adjacent periods, late conflicts,
source preservation, bounded capacity and cancellation. The workspace is in-memory; the durable journal/store pair below adds persistence.
Extraction from live batches, authenticated review UI and application scheduling
remain to integrate before
claiming end-to-end SQD-029 completion. No live model quality/cost is measured.

## Durable journal

`ConsolidationArchive` records the immutable originals, predicate catalogue,
proposal batches with stable IDs, and exact review commands. `workspace()` replays
those commands through the same validators to reconstruct conflicts, versions
and review history. It never trusts a serialized approved/conflicted status.
The version-1 canonical JSON envelope rejects unknown fields, forged citations
and noncanonical encodings. It is limited to 2 MiB and 512 operations in addition
to the workspace's existing limits; oversized appends leave the archive unchanged.
An exact batch replay does not append another operation.

`PostgresConsolidationStore` binds an actor and stores this private journal in
runtime migration 011. Save genesis before appending any operations. Each later
save must match the exact stored predecessor and add one operation; the SQL
trigger independently preserves the immutable header and full command prefix.
A byte-identical retry succeeds after a committed write with an unobserved
acknowledgement. Concurrent different appends cannot both win. On conflict or
ambiguous transport failure, reload and inspect the durable state; never create
a fresh proposal or review key to conceal uncertainty. The adapter bounds database
I/O to five seconds and closes/joins an owned connection on cancellation.

SQL rejects non-genesis insertion, deletion, truncation, source replacement and
history rewrites. Backups and retention remain separate work; this migration
intentionally adds no destructive cleanup. Review authentication is still a trusted
host responsibility, and private database access is not granted to models.
Calling `workspace()` gives an inspection/replay copy; mutations to that copy are
not persisted. Apply mutations to the archive and save it before reporting them
as durable. Export only from a freshly loaded, committed archive, with the same
limitation on previously returned copies described above.

`bash Scripts/test-issue.sh SQD-029-DURABLE` uses real isolated PostgreSQL and
separate clients to verify stable IDs, review reconstruction, exact retry,
concurrent append CAS, late conflict withdrawal, original preservation, actor
isolation, deadline refusal, malformed archive rejection and SQL history guards.
This qualifies persistence and client reload, not process SIGKILL, live extraction,
HTTP approval authentication or application scheduling. Those integrations remain
open in #29; the earlier reference adapter's lack of persistence is addressed by
this explicit journal/store pair.

## Authenticated server review

The normal server now mounts these actor-bound routes behind its existing bearer
boundary and origin checks. Responses use JSON and `Cache-Control: no-store`.

- `GET /api/v1/consolidations/:journal` lists at most 256 proposal summaries with
  journal version, proposal versions, subject, predicate, criticality and state.
- `GET /api/v1/consolidations/:journal/proposals/:proposal` previews the exact
  value, UTC valid interval, original texts, quotations, source IDs, contradictions
  and any persisted reviewer/time. Evidence is untrusted data, not HTML or proof
  of semantic truth. A UI must render it as text. Responses are capped at 1 MiB.
- `POST /api/v1/consolidations/:journal/proposals/:proposal/decision` accepts a
  closed JSON body of four strings, at most 1024 bytes, with exactly one
  `application/json` Content-Type:

```json
{"schemaVersion":"1","journalVersion":"1","proposalVersion":"0","decision":"approved"}
```

`decision` is `approved` or `rejected`. Versions are canonical decimal strings
between 0 and 512. The actor/reviewer and decision time come from the authenticated
host, never from request fields. The selected proposal's contents are immutable;
matching both journal and proposal versions binds the review to the exact preview.
Any changed journal, stale proposal, existing decision or conflict returns 409.
Conflicts cannot be overridden. Unknown or foreign resources return 404, malformed
input returns 400, and storage failure returns 503 without a successful review
response. A 200 response is emitted only after saving the archive. If a response
is lost, fetch the preview to inspect its durable decision; do not change a key
or silently retry a different decision. A retry with old versions returns 409.

The same owner bearer currently authorizes private review, as it does existing
approval decisions. This is explicit owner validation of private memory; it does
not mint an ActionGateway permit or approve a world mutation/external tool.
A server restart reloads the durable review. An API response records its returned
journal version and must not be treated as a perpetual permission after later
contradicting evidence arrives.

`SQD-029-HTTP` exercises normal `ServerComposition.live` over loopback with real
PostgreSQL: preview/evidence, approval and rejection, a second server instance,
foreign actors, no authentication, closed/duplicate/escaped bodies, stale versions,
contradictions and a failing-store fixture. It does not claim a browser UI, a
multi-principal approval model, archive import, or live model extraction. Journals
are still provisioned by the host through the archive/store API.
