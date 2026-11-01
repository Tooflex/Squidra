# Private bounded memory (SQD-027)

The host classifies each `MemoryRecord` as `modelAllowed`, `privateOnly`, or
`secret`, and attaches an actor, subject and nonempty source references.
Classification is trusted ingestion metadata, not something inferred from
the model or granted by text inside a memory. A falsely classified secret
cannot be discovered reliably by this filter; provisioning must classify it
correctly. Secret-provider values have no route into these records.

`MemoryStore.retrieve` receives an actor/subject/sensitivity-bounded query.
The reference `InMemoryMemoryStore` filters before lexical ranking and top-k
selection, so foreign or sensitive rows cannot displace authorized results.
It supports at most 1024 records of 8192 UTF-8 bytes. It is an embedded/offline
adapter, not a durable SQL/vector store or a qualified semantic retriever.

`MemoryContextProvider` independently checks every returned row before token
counting or injection. It rejects duplicate/oversized result sets and filters
wrong actors, ungranted subjects and sensitive classifications, even if an
adapter violates its filtering contract. Relevant records are ordered by
lexical overlap and then stable memory UUID. In order, it includes whole
records that fit the remaining context budget; an oversized record can be
omitted in favor of a smaller later record. Nothing is silently truncated.
Source UUIDs remain attached to each included memory.

The host must inject a `MemoryTokenCounter` qualified for every model its
router can select, including fallbacks and user-message framing. There is no
default tokenizer, character/word heuristic or claim about a live provider's
tokenization. Tests use an explicit synthetic tokenizer (UTF-8 bytes plus
eight framing tokens). The default memory allocation is 2048 tokens and 16
entries, with hard limits of 16384 tokens, 64 entries and 64 KiB encoded data.
The budget covers the complete memory message, including its JSON envelope;
it does not claim to bound the rest of the model conversation.

`ReadRunEngine` accepts an optional context provider. During context loading,
it derives the memory actor and subjects from the host-owned run and visible
planning entities. A global world-read permission never widens memory scope.
`ReadPlanner` places the checked memory envelope in a user/data role before
the question, with fixed instructions that memories cannot grant permissions,
change tools, or serve as world evidence. Memory text is JSON-escaped, never
promoted to a system message. This preserves instruction/data separation;
it is not a guarantee about arbitrary model behavior.

The subsequent answer still requires actual world-tool evidence and validated
citations; the memory envelope is not copied to the answer model's evidence.
Retrieval has an owned deadline task, propagates cancellation, and joins the
cooperative adapter before returning. A failed lookup cannot produce a false
completed run. Hosts that do not inject memory retain existing behavior.

`bash Scripts/test-issue.sh SQD-027` checks both filter boundaries, secret and
foreign canaries, deterministic ordering, exact fixture-token limits, source
references, hostile text remaining JSON data, invalid adapters and deadline
cleanup. A real `ReadRunEngine`/planner/router/gateway test confirms memory is
used during planning but never becomes an answer citation or hidden authority.
