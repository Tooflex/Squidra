# Synthetic frame evidence integration

`PostgresFrameIngestion` is an opt-in host composition for an authored fixture.
It connects `FrameImporter`, `ContinuityEntityResolver`, the immutable world
journal, and location projection recovery. The default server does not activate
it. The optional authenticated HTTP profile below exposes it explicitly; an image
import UI remains to integrate.

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

The normal server now offers the explicit bounded import profile below. The next
integration step is the browser import/question/evidence flow. Live inference
requires T11 qualification; this composition does not close the broader vision
and demo stories.


## Explicit normal-server HTTP profile

Keep the regular owner token, actor, database and exact UI-origin configuration.
To opt in, supply all five variables (partial configuration is rejected):

- `SQUIDRA_SYNTHETIC_IMPORT=1`
- `SQUIDRA_SYNTHETIC_FIXTURE`: absolute path to the frozen repository file
  `fixtures/providers/vision-synthetic.v1.json`
- `SQUIDRA_SYNTHETIC_CAMERA_ID`: host-selected camera UUID
- `SQUIDRA_SYNTHETIC_SCENE_ID`: existing scene entity UUID belonging to the actor
- `SQUIDRA_SYNTHETIC_COORDINATE_FRAME_ID`: existing coordinate frame UUID belonging
  to the same actor

The host must provision the scene and coordinate frame through its trusted local
setup. Startup checks their ownership; it does not invent a calibrated scene or
silently create entities. `check-config` validates configuration/file format;
database ownership is checked when `serve` starts. The fixture is read through a
bounded regular-file, no-follow descriptor (32 KiB maximum), and the synthetic
model verifies its frozen SHA256. Changed fixtures and unsupported profiles fail;
there is no fallback to another provider. With no variables, the route is absent.

`POST /api/v1/frames/import` requires the normal authenticated owner boundary,
allowed browser origin, exactly one JSON content type, and this closed body:

```json
{"schemaVersion":"1","imageBase64":"<canonical base64 PNG>","permitsLocalProcessing":true}
```

The request body is at most 1 MiB; decoded media is at most 512 KiB for this HTTP
profile. The lower-level PNG port supports larger envelopes, but this transport
keeps the existing strict JSON/boundary cap. Consent is a required Boolean and
applies only to this request's actor/camera with a ten-second monotonic deadline;
it never permits cloud transfer. Actor, camera, scene, frame UUID, timestamps,
model and publication state cannot be supplied in the body. The host generates
a fresh frame UUID and observes receipt time in UTC; capture/occurrence time is
unknown. Journal recording time remains database-owned.

Success is HTTP 201 only after durable batch publication and projection recovery.
The versioned JSON receipt includes `deployment: synthetic`, `basis: inferred`,
`mediaRetained: false`, model/version, image hash, camera/frame, scene and spatial
coordinate-frame IDs, observation event, entity/location-event references,
`observedAt`, `knownAt`, and the 1000 ms half-open validity duration. These dates
and entity IDs can be used by the existing world read routes to inspect evidence.
The receipt's coordinate frame is not an image ID or proof of metric calibration.

Invalid/duplicate fields, noncanonical base64, malformed PNG and excessive decoded
media return 400 (body overflow returns 413). Missing consent returns 403.
A valid PNG absent from the exact authored fixture returns 503, never fabricated
detections. Provider/storage details are filtered. No bytes or masks are retained.
The existing authentication, origin and no-store behavior applies to the route.

Each accepted POST is a new observation, with a new host-owned frame identity.
There is no automatic retry or client-selected idempotency key. If the connection
fails after publication, the result is unknown; inspect the journal/world state
before intentionally making a new observation. A staged association may remain
after a failed publication, as described above. The HTTP client cannot recreate
the host frame context for an exact internal retry.

`SQD-020-HTTP` runs three Swift tests with real isolated PostgreSQL and normal
`ServerComposition.live`: explicit/frozen configuration and symlink refusal,
authenticated import/provenance readback, negative consent/identity/shape/PNG/size/
unknown-image cases with no journal writes, and the default absent route.
It is an HTTP/PostgreSQL check, not a browser, SAM, live-model or Linux qualification.

## Read-host scope for imported entities

An explicitly injected `ReadHostConfiguration` can opt into
`allowImportedEntities`. This requires an explicit import profile;
without it composition fails. The default is false. The offline CLI has no
configured language model; the explicit Meta qualification profile can use this
imported-entity scope for questions, with separate cloud-data consent and budget
settings in [providers.md](providers.md). This scope flag alone does not enable
cloud inference.

When opted in, a selected entity is resolved from immutable actor-linked
`perception.frame_imported` events in the configured camera, scene and coordinate
frame. The detection must explicitly name that entity in the versioned journal
payload. The scene itself, an unrelated existing entity, and another actor's or
camera's detections do not receive a grant. Labels are host-authored; model text
and client-supplied labels cannot add entities. Existing explicitly configured
entities retain their original semantics.

Admission, tool execution policy and incomplete-run recovery use the same lookup.
Each request still has one selected planning entity and only `world:read`; no
`world:all` or write permission is introduced. Membership queries use bound SQL,
the existing entity-array index, a bounded result and deadline/cancellation.
The lookup is rebuilt from PostgreSQL after process restart rather than relying
on a mutable in-memory authorization list. Changing host scope changes subsequent
admission/execution/recovery permission; completed output remains governed by the
existing actor-bound replay policy.

`SQD-020-HTTP` covers the real import followed by run admission and an actual
ReadRunEngine execution using an explicitly injected scripted test model. Its
answer cites the imported source event and preserves the exact observation time.
Fresh application compositions resolve the same imported entity again. The tests
also cover opt-out, missing profile, unrelated IDs, foreign actor/camera/scene/
coordinate frame, global target and write-scope rejection. This is not yet a
browser qualification of the complete question flow or a live Meta/SAM call.

## Admitted cloud publication

`FrameScenePolicy` generalizes the host's camera-to-scene assertion;
`SyntheticScenePolicy` remains a source-compatible alias with synthetic defaults.
An explicit `cloudIdentity` must be a cloud deployment. PostgreSQL ingestion
requires the model to match that exact identity and requires a
`VisionCloudAdmission`; per-frame cloud-transfer consent is checked before
inference and again before publication. A cloud model with the default synthetic
policy is rejected. No HTTP cloud activation is implied by this library API.

Cloud observations persist `deployment=cloud`, the actual model ID/version and a
`cloud-frame:<image-sha256>` source. Synthetic observations retain their existing
values. Both produce **inferred scene membership** under the host assertion;
image coordinates do not become calibrated world coordinates. The existing
one-second validity bound, atomic observation/location batch, immutable source
links and projection recovery remain unchanged. Raw image, mask and appearance
bytes are not added to the journal. Missing detection confidence remains a
publication error rather than an invented score or a partial frame.

`PostgresImportedEntityReadScope` matches the policy deployment. Cloud policies
add exact model-ID/version matching to the existing actor, camera, location and
coordinate-frame checks. Cloud evidence cannot enter a synthetic read scope or a
scope for another model alias. Permission still comes from immutable observation
membership, not a provider label or a mutable tracking cache.

The local SQL suite replays captured SAM output through the real native adapter,
importer, association store, journal and projection using fake transport/budget.
It verifies cloud provenance, exact source confidence, denied transfer consent,
missing admission, wrong identity/read scopes and no writes for unknown scores.
No external API call, budget-ledger mutation or schema migration is involved.

## SAM server and browser configuration

The explicit `SQUIDRA_SAM_IMPORT=1` profile selects SAM 3.1. Configure all of
`SQUIDRA_SAM_CONCEPT`, `SQUIDRA_SAM_CAMERA_ID`, `SQUIDRA_SAM_SCENE_ID`,
`SQUIDRA_SAM_COORDINATE_FRAME_ID` and `SQUIDRA_SAM_CLOUD_MEDIA_CONSENT=1`.
The scene and coordinate frame must already exist for the configured actor.
This profile is mutually exclusive with `SQUIDRA_SYNTHETIC_IMPORT`.
It shares `SQUIDRA_META_BUDGET_DIRECTORY` and the credential loader with the
Meta question host: exactly one of `MODEL_API_KEY` or `MODEL_API_KEY_FILE`.
The private file must be an owned, regular, single-link 0600 file, with no symlink.
Never place a key in a checked-in configuration. The existing dated budget ledger
must be preserved; startup does not initialize or reset an allowance.

`SQUIDRA_PROFILE=meta-qualification` additionally enables the Meta question host
with its existing model and text-cloud-consent settings. Imported entity grants
use the selected import policy's exact model, camera, scene and actor scope.
The default configuration still has neither import nor cloud questions enabled.

Authenticated `GET /api/v1/frame-import-capabilities` exposes deployment, byte
limit and whether cloud consent is required; without an import profile it is 404.
Synthetic POST bodies retain their three fields. SAM POST bodies require exactly
`schemaVersion`, `imageBase64`, `permitsLocalProcessing` and
`permitsCloudTransfer`; both consents must be true. SAM accepts PNG up to 64 KiB
and 1024 × 1024 pixels. The complete import has a 25-second deadline within the
30-second HTTP boundary; the UI waits up to 35 seconds and never retries a POST.
Receipts carry the actual `cloud` deployment and `meta.sam` / `alias:sam-3.1`.

The browser reads capabilities before showing the form, requires an unchecked
per-image transfer consent and clears it after submission or logout. It rejects
a receipt with a different deployment or SAM identity. Its non-retention message
applies to Squidra only; Meta retention depends on account terms. Scene membership
remains inferred, without pixel-to-world calibration. Offline configuration,
captured-provider HTTP/SQL and browser tests do not establish a new live-provider
qualification or incur a paid API call.

## SQD-020 acceptance evidence

| Requirement | Implementation and evidence |
| --- | --- |
| Bounded image type, size and consent | `PNGFrame`, `FrameImporter`, SAM admission and HTTP closed inputs; negative type/size/consent/actor/deadline tests |
| Normalized detections | Native one-bit mask decoding, half-open pixel boxes, scores and mask checks; captured SAM raster/reference vectors and real public PNG run |
| Host frame/camera identifiers | `FrameContext` binding and output equality checks; HTTP cannot choose actor/frame/camera; actual SQL lineage checks |
| Model version | Exact identity binding and `alias:sam-3.1` provenance; hosted alias is explicitly not an immutable weight revision |
| Offline fake plus verified real adapter | Authored synthetic contract remains separate from captured provider data and the normal server's opt-in SAM adapter |
| Explicit unavailable/error behavior | Missing admission/budget denial, provider transport failures, invalid output and bounded cancellation tests; HTTP errors never become fixture success |
| Executed checks | `SQD-020` aggregate covers offline, SAM wire/native/admission, SQL and HTTP suites; PR251 records a successful real SAM → Meta → browser/SQL run |

The feature evidence is on the current macOS development host. Linux deployment
qualification belongs to the remaining platform/release checks; neither this
acceptance nor a hosted alias asserts broad scene accuracy, account-wide zero
retention or calibrated world coordinates.
