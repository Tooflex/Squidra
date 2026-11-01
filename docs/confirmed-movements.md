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

The current component emits in-memory reports. A host must persist the full epoch
boundary and source evidence, then publish with a unique event ID and conflict
checking to obtain durable deduplication. Arbitrary sliding windows are **not**
equivalent epochs and must not be presented as exactly-once delivery. Wiring this
into the immutable world journal and qualifying restart/replay remains part of
open issue #43; the component gate alone does not close it. No notification or
physical action is dispatched by this detector.

Run `bash Scripts/test-issue.sh T07-UNIT` for controlled movement, jitter,
repetition/duration, uncertainty, contradictions, occlusion, identity/calibration
changes, stable replay IDs, scope, bounds and cancellation regressions. These are
synthetic geometry checks, not a vision model F1 evaluation or sensor calibration.
