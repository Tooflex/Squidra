# ADR-010: Conservative relations from calibrated 3D evidence

Status: Proposed; adoption follows the authorized PR merge.
Sources: SRS §§7.3, 14 SQD-022; SDD §7. No physical sensor or model qualification is claimed.

## Decision

`CalibratedRelationExtractor` evaluates one ordered pair in constant bounded work.
Inputs are host-supplied actor-owned observations and one calibrated 3D Cartesian
coordinate frame in metres. The signed up axis is explicit; the other two axes
form its horizontal plane. AABBs are aligned to that exact frame. No transform,
depth estimation, camera calibration or entity association occurs here.

The host must supply verified calibration identity/version and a conservative
coordinate-wise maximum error, plus confirmed entity associations. This contract
does not establish the truth of calibration supplied by a sensor adapter. Both
objects must have the same actor/frame, different confirmed entity IDs, calibrated
3D geometry and overlapping half-open validity. Missing frame, depth, calibration,
2D-only input or candidate identity produces a typed abstention. There is no API
that accepts a mask and returns metres. Frames cannot be silently transformed.

Coordinates are finite and bounded to ±1,000,000 metres, each box extent is at
least 1 micrometre, and each measurement/calibration error is 0–10 metres.
Every coordinate is interpreted as an interval expanded by the box error plus
frame calibration error plus 1 nanometre of numeric allowance. Both objects pay
this error separately; correlated calibration errors are not assumed to cancel.

## Rules, version calibrated-aabb-1

- `inside`: the subject's expanded AABB lies inside the object's contracted AABB
  on every axis, with at least the configured containment margin. Boundary touch
  or uncertain containment is insufficient.
- `on_top_of`: the entire possible subject-bottom/object-top gap lies within
  ±contact tolerance; the subject bottom is definitely above the object's vertical
  centre; guaranteed horizontal intersection area divided by the subject's maximum
  footprint area meets the configured fraction. This geometric rule is inferred;
  it does not prove physical load-bearing contact or material solidity.
- `next_to`: the worst-case horizontal AABB surface gap is within the configured
  distance, the best-case gap is strictly positive, and guaranteed vertical overlap
  divided by the larger maximum object height meets the configured fraction.
  This is symmetric when the ordered pair is reversed. `inside` and `on_top_of`
  are directional. No centre-distance substitution or negative spatial fact occurs.

Defaults are 0.25 m adjacency, 0.01 m contact tolerance, 0.001 m containment margin,
0.5 horizontal support fraction and 0.5 vertical overlap fraction. The policy's
identity and all threshold values accompany each result. These are explicit
initial rules, not learned or measured quality thresholds. Equality at a nominal
threshold can abstain because the conservative numeric/error allowance still
applies. Objects with errors too large to support a rule abstain.

Each result preserves actor, subject/object, coordinate frame, both complete source
references (observation, camera, image frame, model/version, original timestamps,
time zone and confidence), calibration identity/error, policy and intersected
validity. Basis is always `inferred`; absence of a relation means unknown under
these rules, never a persisted false fact. Reported confidence is the minimum of
the two source confidences when both are known, otherwise unknown. It is a source
summary, not a calibrated relation probability, measured accuracy or certainty
that the latest observation is still current. Publication into the bitemporal
journal and answer grounding remain separate boundaries.

## Qualification and limits

`bash Scripts/test-issue.sh SQD-022-CONTRACTS` covers independently authored scenes
for containment, contact/support, adjacency, direction and six signed up axes;
uncertainty and threshold boundaries; missing depth/2D/calibration/identity;
actor/frame isolation; half-open validity; unchanged provenance/unknown confidence;
and invalid numeric contracts. These synthetic rules tests do not measure the
SRS scene-accuracy target or qualify an external vision model.

SQD-021 association, perception composition and broader spatial scene qualification
remain prerequisites for completing parent SQD-022. No sensor, package upgrade,
SQL migration, asynchronous I/O or application activation is added here. Rollback
removes this isolated evaluator and its suite; there is no persisted state.
