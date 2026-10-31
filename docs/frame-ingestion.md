# Synthetic frame evidence integration

`PostgresFrameIngestion` is an opt-in host composition for an authored fixture.
It connects `FrameImporter`, `ContinuityEntityResolver`, the immutable world
journal, and location projection recovery. The default server does not activate
it. There is no image HTTP endpoint or UI in this profile.

The host supplies a `SyntheticScenePolicy`: authenticated actor, camera, named
scene entity, existing coordinate frame, and validity of 1–1000 milliseconds.
The scene mapping is an explicit host assertion. Pixel boxes never establish
depth, metric coordinates, containment, or calibration. All resulting location
facts have `basis: inferred`; detection confidence is the authored source value,
not measured location or identity accuracy. Unknown confidence is rejected.

The host also supplies fresh `FrameContext` identities/times and actor/camera
consent with a monotonic expiry. Only synthetic `VisionModel` deployments are
accepted. Models must cooperate with deadlines and cancellation. This is not a
SAM adapter, live provider qualification, or fallback for unavailable inference.

The bounded path is:

1. Validate actor/camera/consent; import a bounded PNG using the existing checks.
2. Require 1–16 detections with known confidence; resolve durable identities with
   a maximum of 32 tracks. Ambiguous matches remain separate candidates.
3. Publish one `perception.frame_imported` observation followed by one
   `world.location_asserted` event per detection, in a single journal transaction.
4. Recover the actor's location projection before returning a successful receipt.

The observation contains the image SHA256, camera/frame, synthetic model/version,
pixel boxes/labels, identity assignment kinds/scores, and host scene policy.
It stores no image bytes, masks or appearance vectors. Each location event's
causation ID points to the observation. Source IDs begin with `synthetic-frame:`.
The observation confidence is the minimum of the supplied detection confidences;
each location retains its own detection score. Unknown occurrence remains nil,
observation time and IANA zone are preserved, and database time determines the
journal's authoritative recorded time. The host input's recorded time is staging
metadata, not a replacement for database transaction time.

The valid interval is `[observedAt, observedAt + policy duration)`, representing
only that short observation window. It neither asserts movement time nor extends
an object's location indefinitely. Existing grounding rules reject inferred
current-location claims by default.

Publication is limited to 17 events and 256 KiB of aggregate payload. The
host-owned frame UUID identifies the observation and its stream; fixed stream
keys and canonical payload equality make identical publication idempotent.
Changed scene policy or content for the same frame conflicts. All events must
be newly created or all replayed; mixed batches roll back. The coordinate frame
and entity ownership must exist in the database. No schema migration is needed.

Association staging and journal publication are separate transactions. A journal
failure can leave a staged association but never part of the evidence batch.
Re-submit the identical **last frame** with valid consent to reuse that staged
identity. Once another frame advances the association cache, older-frame imports
are rejected; there is no automatic inference or identity reconstruction retry.
If publication committed but projection recovery failed or the response was
lost, the journal remains authoritative. Startup recovery can rebuild it, and
an identical last-frame submission replays the journal without duplicate facts.
A caller must treat an interrupted response as an unknown outcome, not proof
that nothing committed. There is no automatic retry or image retention service.

Run `bash Scripts/test-issue.sh SQD-020-PUBLISH` with the configured container
engine. The isolated PostgreSQL tests exercise the authored PNG through durable
association, publication, projection, the actual read engine, router and gateway,
and a grounded historical answer citing the persisted location event. Language
model outputs are controlled fixtures; no live-model quality or cost is measured.
The suite also covers rollback, projection reconstruction, scope/consent/bounds,
unknown confidence, conflicting replay, and cancellation during a blocked append.

The next integration step is an authenticated, bounded import API with host scene
configuration and an explicit offline demo profile. Live inference requires T11
qualification; this composition does not close the broader vision/demo stories.
