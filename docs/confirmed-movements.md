# Confirmed movement evidence (T07)

`ConfirmedMovementDetector` replays a complete, bounded epoch for one actor and
entity. The host chooses the epoch ID, entity type and versioned policy; labels
from a model do not select thresholds. Each type has a minimum displacement,
destination tolerance, repeat count, minimum duration and maximum observation gap.
Unknown types fail rather than inheriting an arbitrary threshold.

Only confirmed identity with calibrated 3D boxes in the exact same frame is
eligible. Displacement is between box centres. Coordinate-wise box errors and
both calibration errors expand the distance interval; the **minimum** distance
must exceed the movement threshold. Repeated destinations must all be mutually
consistent within the **maximum** distance tolerance. These rules infer movement
of measured centres, not a physical trajectory or a guarantee about a changing
object's shape. No 2D mask becomes a metric position.

The first eligible sample establishes a baseline. Enough distinct subsequent
images must remain displaced and mutually consistent for the configured duration.
After emission, the last confirming sample becomes the new baseline. Jitter
clears pending confirmation. An inconsistent destination restarts confirmation;
all observations remain in the report. Occlusion, missing depth, ambiguous
identity, a long gap, changed calibration/frame/camera/model reset the baseline.
The detector does not connect positions across an unseen interval.

Different observations at the same timestamp are retained as contradictions and
reset confirmation irrespective of input order. An exact duplicate observation
is ignored for counting; a reused observation ID with changed contents fails.
Reusing an image frame as a new observation also fails. Inputs must be time ordered
and their validity must include the observed instant. Actor/entity mixing fails.
At most 1,024 samples and 16 pending confirmations are retained per evaluation;
oversized histories fail explicitly. Cancellation yields no partial report.

Each emitted event contains the original baseline, all confirming observations,
coordinate frame/calibration, policy, conservative displacement, epoch and entity
identity. Occurrence timestamps remain unknown where the source says unknown.
The event is explicitly inferred; no synthetic confidence is fabricated.
Event IDs are deterministic SHA-256 values of the rule, epoch, scoped entity,
policy values and ordered supporting observation IDs. Replaying the same epoch
or extending its unchanged prefix preserves existing event IDs.

`MovementPublisher` writes confirmed events to the immutable world journal as
`perception.movement_confirmed`. Each event has its own deterministic UUID stream
(derived from the first 128 bits of the event hash); the full hash is retained as
its idempotency key, source ID and payload ID. Hash/UUID collisions cannot silently
merge different evidence: journal uniqueness and payload comparison reject them.
The payload preserves baseline and confirmation geometry, errors, source times,
IDs, confidence, frame/calibration, exact selected policy and an explicit
host-supplied `synthetic` or `sensor` origin. The journal confidence is the minimum
source confidence, explicitly labelled as such, not a movement probability.
Unknown source confidence fails the whole report before any append; it is not
converted to zero or certainty. The in-memory report remains available.

Publication preflights at most 128 events, then appends sequentially within the
caller's deadline. A failure can leave a committed prefix. Replaying the same
report reuses it and completes the remainder; changed provenance or payload is an
idempotency conflict. The return is not a promise of report-level atomicity.
Cancellation or an expired deadline prevents further appends. The location
projector advances over movement evidence without generating `located_at` facts.
No notification or physical action is dispatched.

`MovementEpoch` seals the complete input history, policy, entity type, origin and
epoch identity. `PostgresMovementEpochStore` stores it before publication in the
actor-scoped `movement_epochs` table. Saves are create-only: an exact retry is
idempotent, while changed input or policy under the same epoch ID conflicts.
Database triggers reject updates, deletion and truncation. The entity foreign key
must already belong to the actor. Unknown confidence and occlusions are stored
without conversion to journal confidence.

The versioned codec preserves floating-point bit patterns (including timestamps),
all geometry kinds, coordinate/calibration metadata, candidates and missing
observations. Typed reconstruction reruns the source and detector validations;
canonical round-trip comparison rejects unknown fields and noncanonical values.
The maximum is 1,024 samples and 2 MiB of serialized state, with explicit failure
rather than truncation. This is private evidence with the same access boundary as
the actor's world journal; it is not an HTTP input format.

`MovementEpochRecovery.submit` saves, reloads and publishes. Its `recover(epochID:)`
entry point reloads the entire epoch and recomputes the report before publishing;
callers cannot replace the policy or input during recovery. An unknown-confidence
publication remains explicitly nonpublishable with its original history retained.
Recovery may be repeated after partial publication because event keys are stable.

This sealed-epoch profile is for completed bounded sequences. Arbitrary sliding
windows are **not** equivalent epochs; changing boundaries can change detected
movement identity. Continuous streaming and automatic enumeration of pending epochs are separate
host scheduling concerns; this profile exposes explicit submit/recover APIs for
completed sequences.

Run `bash Scripts/test-issue.sh T07-UNIT` for controlled movement, jitter,
repetition/duration, uncertainty, contradictions, occlusion, identity/calibration
changes, stable replay IDs, scope, bounds and cancellation regressions. These are
synthetic geometry checks, not a vision model F1 evaluation or sensor calibration.

Run `bash Scripts/test-issue.sh T07-SQL` through the isolated database helper for
real journal publication, loss of acknowledgement after commit, resumption of a
partially published report, concurrent duplicate replay, changed-provenance
conflicts, actor isolation and location-projection separation. This test uses two
PostgreSQL clients and reloads saved input by epoch ID. It also checks immutable
state, foreign-actor lookup, unknown-field rejection and exact codec round trips
for missing depth, 2D evidence, candidate identities, unknown confidence and
occlusions. It does not claim an actual process-kill recovery test.

Migration: `world/003_movement_epochs.sql` adds one immutable table and two mutation
triggers. Application rollback can leave this evidence table intact. No existing
world event or fact is rewritten, and deleting evidence is not a rollback step.

## Complete T07 acceptance gate

`bash Scripts/test-issue.sh T07` runs the rule regressions, real PostgreSQL
persistence/replay checks, and `T07-CRASH`. The process fixture saves a sealed
sequence containing two annotated movements. At the first boundary it waits
after the source epoch commits; at the second it waits after the first movement
event commits. The harness sends SIGKILL only to the exact child it created and
verifies that child's signal exit before starting a new process.

The restart manifest contains actor ID, epoch ID and boundary name only. The new
process loads the original input and policy from PostgreSQL, runs recovery twice,
and verifies exactly two journal events with the expected full-hash identities.
An already committed first event must remain unchanged. The fixture requires an
explicit test opt-in and isolated database credentials; it is a separate test
executable, not part of the production server startup path.

These checks qualify deterministic inferred movements, repetition, conservative
uncertainty and durable deduplication for completed bounded epochs. They do not
measure real vision F1, imply sensor calibration, or authorize external effects.
