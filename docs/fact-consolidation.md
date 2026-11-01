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
not a public authentication mechanism or a tool permission. A future HTTP/agent
integration must connect it to the existing exact-command approval gateway.

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
source preservation, bounded capacity and cancellation. This is an in-memory
reference implementation. Durable proposal storage, extraction from live batches,
authenticated review UI and application scheduling remain to integrate before
claiming end-to-end SQD-029 completion. No live model quality/cost is measured.
