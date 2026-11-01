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

A host must still persist the full epoch boundary and source history (including
contradictions and occlusions) to reconstruct the report automatically after a
process restart. Published event evidence alone is not that full input history.
Arbitrary sliding windows are **not** equivalent epochs. Automatic host restart
and full source-history recovery remain part of open issue #43; the component and
publication gates alone do not close it.

Run `bash Scripts/test-issue.sh T07-UNIT` for controlled movement, jitter,
repetition/duration, uncertainty, contradictions, occlusion, identity/calibration
changes, stable replay IDs, scope, bounds and cancellation regressions. These are
synthetic geometry checks, not a vision model F1 evaluation or sensor calibration.

Run `bash Scripts/test-issue.sh T07-SQL` through the isolated database helper for
real journal publication, loss of acknowledgement after commit, resumption of a
partially published report, concurrent duplicate replay, changed-provenance
conflicts, actor isolation and location-projection separation. This test uses two
PostgreSQL clients; it does not claim an actual process-kill recovery test.
