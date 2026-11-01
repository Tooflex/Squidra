# Provider qualification

Public contracts first observed on 2026-10-31; authenticated catalog and minimal
text/image inference verified on 2026-11-01 as detailed below. The default server
remains offline-only. These bounded probes do not establish general quality,
account retention, billing reconciliation or safe production spending bounds.

## Documented contracts versus execution

| Family | Documented identifier | Documented interface | Squidra execution status |
| --- | --- | --- | --- |
| Spark | `muse-spark-1.3` | Hosted multimodal input, text output | HTTP 200; one bounded JSON text probe passed |
| Wonder | `muse-wonder-1.0` | Hosted multimodal input, text output | HTTP 200; one bounded JSON text probe passed |
| Glimmer | `meta-models/Muse-Glimmer-30B` | Self-hosted image/text to text | Weights not downloaded; runtime unqualified |
| SAM | `sam-3.1` | Hosted prompted image/video segmentation | HTTP 200; one synthetic image mask decoded and compared with expected pixels |

The hosted base is `https://api.meta.ai/v1`, authenticated with a Bearer
`MODEL_API_KEY`. Responses uses `POST /v1/responses`. Public API documentation
also describes Chat Completions and Messages compatibility; their availability
must be checked per selected model. Spark and Wonder accept text, images,
audio, video and PDF input. Wonder Full is a separate Muse Code offering;
there is no qualified Wonder Full Model API identifier here. Glimmer has no
hosted Meta Model API endpoint in this matrix.
Sources: [overview](https://dev.meta.ai/docs/overview),
[models](https://dev.meta.ai/docs/models),
[Glimmer](https://dev.meta.ai/docs/muse-glimmer/).

SAM output requires a dedicated parser: streamed special-token text contains
explicit frame and object IDs, pixel boxes and base85-encoded masks. Frame IDs
can skip or arrive out of order; object IDs belong to a response and must not
become persistent world entity IDs. Empty output can mean no matches.
Confidence is optional and must not be invented when absent. This is a distinct
wire contract from the normalized JSON fixtures below. A pinned official reference decoder has now decoded one real synthetic-image
response (see below); the bounded native Swift image decoder is described below.
Source: [SAM output](https://dev.meta.ai/docs/sam/reading-segmentation).

## Versions, weights and licenses

`fixtures/providers/sources.v1.json` records retrieval dates, exact response-byte
SHA-256 values, URLs and public revision metadata. A document hash records what
was fetched; it does not pin hosted weights. Cloud model aliases have no
qualified immutable build revision here.

Public metadata observed these revisions; no weights were downloaded:

| Repository | Revision | Qualification limits |
| --- | --- | --- |
| `facebookresearch/sam3` | `f1647e8d0c1d280991f4d1b7d974c2704537fe66` | Source revision only |
| `facebook/sam3` | `3c879f39826c281e95690f02c7821c4de09afae7` | Gated weights; access untested |
| `facebook/sam3.1` | `daa63191845a41281374e725f4c9e51c7a824460` | Gated weights; access untested |
| `meta-models/Muse-Glimmer-30B` | `cec94fcfd6512f2cfe708138c32533b346ea4f69` | Apache-2.0 metadata; runtime untested |

The SAM source uses the custom SAM License; it must not be labeled Apache-2.0.
Its documented Python/PyTorch/CUDA execution requirements have not been met or
tested in Squidra. Glimmer is a vision-language model, not a mask segmentation
service. Its model card lists Apache-2.0; each artifact and runtime still needs
its own license/dependency review. Public repository visibility or authenticated
metadata retrieval does not establish permission to gated weights or API inference.
Sources: [SAM source at observed revision](https://github.com/facebookresearch/sam3/tree/f1647e8d0c1d280991f4d1b7d974c2704537fe66),
[SAM License](https://github.com/facebookresearch/sam3/blob/f1647e8d0c1d280991f4d1b7d974c2704537fe66/LICENSE),
[SAM weights](https://huggingface.co/facebook/sam3),
[SAM 3.1 weights](https://huggingface.co/facebook/sam3.1),
[Glimmer card](https://huggingface.co/meta-models/Muse-Glimmer-30B).

## Costs and data handling remain unqualified

Published USD rates observed on that date, before any extras or account-specific
terms:

| Hosted model | Input / cached input / output per million tokens |
| --- | --- |
| Wonder Standard | $4.00 / $0.20 / $20.00 |
| Spark Standard | $1.25 / $0.15 / $4.25 |
| Spark Contributor | $0.10 / $0.002 / $0.20 |

SAM pricing is $2.50 per thousand images or $0.20 per thousand video frames,
with a minimum of 50 frames per video request. These are published prices,
not measured spending or safe per-request reservations. No real provider
cost bound is configured. Self-hosting costs and all latency/quality metrics
remain unmeasured. Source: [pricing](https://dev.meta.ai/docs/pricing-rate-limits).

Contributor mode permits training use of submitted content. It is not enabled
or considered consented by Squidra. Standard-mode training restrictions do not
establish zero retention. Default retention has not been qualified for this
account. ZDR needs separate organization enablement and eligible direct Meta API
requests. It excludes features including file uploads, stateful requests,
background requests, web search and Contributor mode; policy-violation and
operational retention exceptions still apply. Do not promise ZDR for a SAM file
workflow. Sources: [Contributor policy](https://dev.meta.ai/help/policies-and-privacy/contributor-tier),
[ZDR policy](https://dev.meta.ai/help/policies-and-privacy/zero-data-retention).

## Authored offline fixture contract

`fixtures/providers/vision-synthetic.v1.json` and
`Schemas/providers/vision-synthetic.v1.json` define **Squidra test data**, not a
captured provider response or a vendor wire format. All images and detections
were authored together. Three embedded 8×8 RGB PNGs show a moving red square
and a stationary blue square. No external image, private scene or licensed
provider output is embedded.

The closed version-1 contract fixes `modelId=fixture.vision`,
`modelVersion=1.0.0`, `provenance=authored_synthetic` and `liveQualified=false`.
Masks contain 64 row-major binary pixels; boxes use source-pixel x/y/width/height
with excluded upper bounds. Appearance vectors and confidence values are
fabricated inputs for deterministic downstream tests, not measured embeddings,
model accuracy or calibrated probabilities. Local detection IDs are not actor,
frame, persistent entity or authorization identities.

A future fake adapter must bind actor, camera, frame, observed/recorded time and
consent from the host, select only exact fixture image hashes, and reject unknown
media. A real adapter requires a separate qualified parser, bounded resources,
provenance and error handling; it must never silently substitute fabricated
scores or detections for failed inference.

Run `bash Scripts/test-issue.sh T11-CONTRACTS`. The nonempty offline suite checks
schema validity, provenance/version rejection, image digests/headers, geometry,
mask/box agreement, duplicate IDs, the scene sequence and qualification/source
records. These tests require no network or credentials and do not qualify live
providers. No new production dependency, migration or server configuration is
introduced. Rollback removes only these qualification artifacts and CI mapping.

## Conditions for live qualification

Before enabling any provider, verify access with securely configured credentials,
record the exact request/response contract and available model revision, review
terms and account-specific retention, enforce cloud/media consent and spending
limits, and capture redacted successful and failing responses. Exercise malformed
output, cancellation, rate limits, timeout, privacy rejection and unavailable
models. Measure tokens or image/frame units, cost, runtime resources and latency.
Gated/self-hosted models additionally need explicit license acceptance and a
qualified runtime. Those steps remain open under T11; public-source or offline
fixture tests cannot close them.

## Meta Responses client preparation (2026-11-01)

The user selected hosted Meta AI and SAM 3.1 APIs and supplied a private key.
Two minimal text probes and one synthetic-image SAM probe now pass. The default
server remains offline.

`MetaResponsesClient` implements a bounded, injectable text Responses contract
for Standard-mode `muse-spark-1.3` or `muse-wonder-1.0`. It requires explicit cloud
consent and a monotonic deadline of at most 180 seconds. It permits 1–64 messages,
64 KiB of input text and 16–4096 output tokens. It preserves system/user/assistant
roles and maps prior assistant text to output_text. A tool-role message is
rejected: the current ModelMessage has no call ID to represent function output,
and tool text must not silently become a system instruction.

Requests set store, stream and background to false, disable truncation, declare
no tools, select minimal reasoning and request an object through
`text.format` JSON Schema. This generic object format does not replace Squidra's
planner/answer schema validation. No previous response ID, file, search tool,
media input, cache identifier or encrypted reasoning replay is requested.
`store:false` is a request setting, not a promise about account-wide retention.

Responses must match the selected model and complete successfully with one
assistant message containing bounded output_text JSON object content. Refusal,
function/tool output, duplicate JSON keys, partial/multiple messages, wrong
content type, oversized bodies and inconsistent token counts fail closed.
Reasoning items are never returned as answer text. An explicit store/background
true echo is rejected. Usage retains input/output/total tokens and optional
cached/reasoning detail; absent detail remains unknown, not zero. It is not
converted to money, and the model alias is not described as a pinned weight
revision. HTTP failures expose fixed typed errors, never provider error bodies.
There is no retry, polling or fallback.

The transport is injected and must enforce response limits while receiving,
refuse redirects and cooperate with cancellation. The client independently
validates the complete response and joins the deadline/cancellation tasks. This
component now has a separate LanguageModel adapter described below. The explicit dated
server qualification profile is described below. General production spending
and account qualification remain separate. No environment key is read and no network transport is
implicitly created by this component.

`bash Scripts/test-issue.sh T11-META-RESPONSES` runs eight offline tests with
hand-authored responses, covering request flags/roles, consent and resource
limits, HTTP failures/no retry, refusal/partial/tool output, model/usage/JSON
validation, encoding/body limits, deadline and caller cancellation. Passing them
does not establish account access, billing, retention, model quality or live
compatibility. Separate live observations below cover only two small text calls.

Contract sources re-read on 2026-11-01:
[Responses protocol](https://dev.meta.ai/docs/protocols/responses),
[Responses reference](https://dev.meta.ai/docs/api-reference/responses), and
[structured output](https://dev.meta.ai/docs/structured-output). The protocol
specifies max_output_tokens as reasoning plus visible output with a minimum of
16, and uses text.format rather than Chat Completions' response_format.


## Explicit HTTPS transport (offline tested)

`MetaHTTPSResponseTransport` accepts a server-side bearer key explicitly and
posts only to the fixed Meta Responses endpoint. It does not read environment
variables or activate the server's cloud configuration. Descriptions redact the
key; invalid bearer characters are rejected. Each request uses an ephemeral
session without cookies, URL cache or credential storage. Redirects are refused,
TLS uses system trust, and interactive authentication is rejected.

The delegate bounds successful response bytes as chunks arrive, rejects an
oversized declared length, and discards non-200 bodies. Caller cancellation and
the monotonic deadline cancel the URLSession task. Errors expose typed status or
transport failures without provider bodies, URLs or credential values. No
application retry is implemented. Foundation may buffer before delegate delivery;
the byte limit applies to the application accumulator, not all TLS/system memory.

`bash Scripts/test-issue.sh T11-META-TRANSPORT` exercises seven tests using an
intercepting URLProtocol with fabricated credentials. They cover request headers,
chunk assembly, error-body discard, declared/chunk overflow, redirect refusal,
deadline/caller cancellation, invalid input and sanitized network failures.
Darwin exercises URLProtocol redirects; FoundationNetworking exercises the
redirect delegate directly because its URLProtocol redirect callback is unsupported. These tests do not
qualify Linux TLS, real Meta access, account retention, inference or billing.

The user's selected deployment for both language models and SAM 3.1 is hosted
API access. Authenticated catalog access now lists SAM with the supplied key.
SAM now has a separate bounded image client and a reference-decoder probe below.
A SAM VisionModel adapter is available, but the server has no cloud import route.


## Monetary evidence and dated text estimates

`ModelResponse.costMicroUSD` is an amount whose provenance is explicit:
`provider_reported`, `local_zero`, `published_rate_estimate` or `unspecified`.
Unannotated adapters and historical archives remain unspecified. Local-zero
requires zero and a local descriptor; an estimate requires a bounded tariff ID.
Routing still reserves the descriptor's qualified per-attempt upper bound,
including failed attempts. A response estimate never reduces that reservation
or establishes qualification by itself.

Plan and answer archives now write version 2 with this evidence. Version 1 is
still accepted as unspecified, never relabeled reported. Unknown fields,
unsupported versions, missing v2 evidence and inconsistent metadata are rejected.
Older binaries cannot read v2 archives: rollback requires preserving those runs
for a compatible reader, not editing archives or replaying paid attempts.
Private model traces emit estimates under `squidra.estimated_cost_micro_usd`;
reported amounts and explicit local zero retain `squidra.cost_micro_usd`.
Unspecified monetary amounts are omitted from traces, while validated output
token counts remain available. Arbitrary rate IDs are not exported to telemetry.

`MetaTextPricing` freezes the Standard text rates rechecked on 2026-11-01 as
`meta-standard-text-2026-11-01`. It calculates with integer nano-USD and rounds
the total upward once to micro-USD. Cached tokens use the cached rate; absent
cache detail is explicitly marked unknown and estimated at the full input rate.
Reasoning tokens already belong to output tokens and are not added again. Input,
output, cache and total counters must satisfy the same bounds as the text client.
This is a text-only estimate, excluding account-specific terms, taxes, media,
tools/search and unknown charges on failed calls. It neither discovers changed
prices nor proves a safe live reservation. Current source:
[Meta pricing](https://dev.meta.ai/docs/pricing-rate-limits).

Offline checks: `T11-META-COST` covers exact arithmetic, cache uncertainty and
invalid counters; `SQD-003-COST` covers routing and both archive versions.
No API key is read by these components. The server credential variable
is `MODEL_API_KEY`, with private `MODEL_API_KEY_FILE` as an alternative in the
explicit qualification profile below. A key alone does not activate cloud calls.


## Authorized live text probes (2026-11-01)

Authenticated `GET /v1/models` returned HTTP 200 and listed Spark 1.3, Wonder 1.0
and SAM 3.1. The endpoint and authentication follow the official
[list-models reference](https://dev.meta.ai/docs/api-reference/models/list-models).
Catalog membership does not prove segmentation capability or inference quality.

The explicit `squidra-meta-qualification-fixture` then called the actual
`MetaResponsesClient` and `MetaHTTPSResponseTransport` once per Standard text
model with a fixed public prompt requesting `{"ok":true}`. Both returned the
expected object through the existing structured-response validator. Each call
used 64 maximum output tokens, a 25-second deadline, store/stream/background
false, no tools and no application retry. No private world data or image was sent.

| Model | Input / output (reasoning included) | Estimated USD | Result |
| --- | --- | --- | --- |
| Spark 1.3 | 20 / 60 (46 reasoning) | 0.000280 | HTTP 200, completed, expected JSON |
| Wonder 1.0 | 20 / 31 (17 reasoning) | 0.000700 | HTTP 200, completed, expected JSON |

Both reported zero cached-input tokens. These amounts use the dated published
schedule, not an invoice. Total estimated token cost is USD 0.000980. The public
`fixtures/providers/meta-text-live.v1.json` contains the fixed prompt, validated
text, usage and exact original-response hashes. It is an anonymized projection,
not a full vendor wire response; raw responses, provider IDs and reasoning
contents are not retained. It does not qualify cancellation under real network
failure, broad answer quality, account retention or SAM geometry parsing.

The user authorized **100 EUR total** across all Meta/SAM tests. The opt-in
`Scripts/test-meta-live.py` reserves **10 EUR per attempt** in the private,
Git-ignored `.build/provider-access/live-budget.json`, before launching inference.
A no-follow lock serializes probes and atomic fsync writes preserve reservations
across failures/restarts. Estimates and failures never refund a reservation.
The two text calls consume 20 EUR of conservative reservations;
this is **not 20 EUR spent**. The SAM probe below reuses this same ledger and cap.
Do not delete the ledger to repeat a probe or refresh pricing.

The reservation deliberately exceeds a full published 1,048,576-token Standard
input context plus the 64-token output cap even for Wonder. The verified
[ECB USD reference](https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/eurofxref-graph-usd.en.html)
was 1.1172 USD per EUR on 2026-10-30. The pricing/FX snapshot expires at
2026-11-02 00:00 UTC; later probes refuse until reviewed and updated while
preserving all prior reservations. This conservative test envelope is not a
production ModelDescriptor qualification or account-level billing control.

Run only with explicit authorization and an owner-only regular credential file:

```sh
python3 Scripts/test-meta-live.py --allow-live --model spark --key-file /absolute/private/key-file
```

The file is read with no-follow, owner, 0600 mode and size checks. The key never
appears in command arguments, reports or fixtures. The fixture requires a live
opt-in and a reservation ID supplied by the driver; do not invoke it directly.
The driver and inference fixture are never run by CI or the offline gate.
Offline Python tests exercise cumulative exhaustion, failure/restart reservation
retention, stale/corrupt records and private-file rejection.


## SAM 3.1 image probe and reference decoding (2026-11-01)

`MetaSAMImageClient` sends one PNG as an inline data URL with explicit cloud-image
consent. It accepts PNG envelopes up to 64 KiB and 1024 × 1024 pixels, a bounded
concept prompt, and a monotonic deadline. The request disables storage,
background work and streaming, and requests one_bit masks and confidence using
string metadata values. Non-streaming segmentation is supported by the official
[request documentation](https://dev.meta.ai/docs/sam/segmenting).

The client accepts only a complete single assistant output_text lane for
sam-3.1. An empty lane represents zero matches; an absent lane does not. Optional
images_processed remains unknown if absent. The returned segmentation text is
**not validated geometry** and is not a VisionOutput. This boundary does not
invent confidence, appearance embeddings, persistent entity IDs or actor/camera
identity. Offline T11-SAM-IMAGE tests cover consent, prompt/media limits, request
flags, empty/missing lanes, usage types, partial/refused/error responses and
cancellation.

The authorized live probe sent only the authored 512 × 512 RGB PNG in
`fixtures/providers/sam-red-square.png`, containing a red square at half-open
coordinates [128,128,384,384]. The fixed concept was `red square`. The actual
Swift client/HTTPS transport received HTTP 200 and images_processed=1. The
returned inclusive box became half-open [128,128,384,383]. The decoded box-local
mask was 256 × 255, with 64,849 foreground pixels. Its intersection-over-union
against the authored source square was **0.9895172119140625**, above the probe's
0.90 threshold. This is one synthetic case, not a general segmentation accuracy
claim. Both observed token confidences were 0.8787879347801208; neither is a
calibrated world certainty.

`Scripts/test-sam-reference.py` verifies and imports the official
meta-sam-parser 0.1.0 wheel, SHA-256
`eca156907911c56cef3a350ffc81c34b7e70655e5fa3ccdddb77042c541a0152`.
It is **SAM License**, not MIT or Apache, and is used only for development
qualification; it is neither vendored nor installed as a server dependency.
Its official package provenance is documented by the
[client libraries](https://dev.meta.ai/docs/sam/client-libraries) and
[package index](https://pypi.org/project/meta-sam-parser/0.1.0/).
The helper caps text at 16 KiB, masks at 16, raster dimensions at 1024 and total
raster area at 1,048,576 pixels **before** calling the reference parser. It rejects
diagnostics, wrong source dimensions, unexpected scale/count and nonbinary
rasters. The parent process bounds reference decoding to ten seconds.

The [shared protocol](https://github.com/meta-models/meta-sam/blob/main/protocol/sam3.md)
specifies inclusive wire corners, a custom base85 arithmetic-coded mask payload,
and independent optional confidence on box and mask tokens. The reference helper
retains both scores independently; an absent score remains null. Native Swift
mask decoding and full-frame reconstruction are now implemented below. Cloud
world ingestion remains disabled pending host integration. Streaming/video and
long-term object identity remain unqualified.

The anonymized live projection in `fixtures/providers/sam-image-live.v1.json`
retains public synthetic segmentation text, image/response/raster hashes and
measurements, without provider IDs or raw HTTP response. Re-decoding that stored
text reproduced the raster hash without another API call. The estimated image
charge is USD 0.002500 at the recorded rate; total text-plus-image estimate is
USD 0.003480, not a reconciled invoice. The same private ledger now reserves
**30 EUR of the authorized 100 EUR** across three attempts; reservations remain
conservative, are never reset, and are not the measured charge.


## Native SAM image decoding

`SAMOneBitMask` ports the one-bit custom base85/range codec from the pinned
reference package. The derived code retains the SAM License and attribution in
`ThirdPartyLicenses/`. No Python runtime is needed by the Swift adapter. Decoding
checks canonical base85 and re-encodes the raster to reject truncated, appended
or noncanonical arithmetic streams. Lossless (`~`), streaming and video profiles
are unsupported. Dimensions are bounded to 1024, text/payload to 192 KiB, and
cancellation and monotonic deadlines are checked throughout raster processing.

`SAMImageSegmentation` accepts a single image frame, unique response-local IDs,
exactly one box and mask per detection, inclusive wire corners and matching
box-local raster dimensions. It rejects unknown/duplicate fields, malformed
confidence, scaling and empty foreground masks. This is stricter than the
reference parser's warning recovery. At most 16 detections, one million local
mask pixels and four MiB of reconstructed full-frame masks are accepted. Pixels
outside each box remain zero. Box and mask confidence remain independently
optional.

`MetaSAMVisionModel` preserves host context and image digest and identifies the
provider version as `alias:sam-3.1`, not immutable weights. Detection confidence
is the minimum only when both scores exist; otherwise it remains absent.
Appearance embeddings are absent. FrameImporter still rejects cloud models,
even with transfer consent: this adapter does not activate paid world ingestion.

Offline `T11-SAM-NATIVE` compares 40 reference-encoded rasters and 18 rejected
streams, exercises geometry, quotas, cancellation and adapter provenance, and
reproduces the captured live raster SHA-256. It makes no paid calls. These checks
qualify the bounded image profile, not arbitrary SAM output or general quality.


## Meta language model boundary

`MetaLanguageModel` bridges the text client to the read engine. It requires an
explicit `MetaTextQualification` from the host, an injected clock and a mandatory
`MetaAttemptBudget`. Qualification identifies the Standard model, expiration
and a conservative per-attempt upper bound including failures. The constructor
checks that the bound covers the published full input context and 4096 output
tokens; that minimum check does not verify account terms or qualify a deployment.
No default qualification or environment activation is supplied by this adapter.
The explicit shared test-budget implementation is described below.

Consent, capabilities, request size/output limits, deadline and qualification
expiry are checked before reservation. The budget implementation must atomically
persist each attempt against a cumulative cap before returning, honor the
monotonic deadline and retain reservations on failures, cancellation or uncertain
outcomes. Attempt IDs are unique even when planning and answering share a request
ID. Authorization latency consumes the same deadline as transport. Usage estimates
do not refund reservations. The existing private 100 EUR test ledger has an explicit Swift implementation
below; the explicit server profile connects it to question execution.

The domain model port lacks function call IDs. Its tool messages are therefore
encoded as JSON objects with `kind=untrusted_tool_data` and the original content,
carried at user-message authority. Existing system/user/assistant messages retain
their roles. No tool result becomes a system instruction or fabricated function
call. Quoting is a representation, not a security boundary: the read engine still
validates generated plans, source citations and permissions. The raw Responses
client continues to reject unrepresentable tool-role messages.

Returned ModelResponse values use the host request ID, explicit hosted alias,
visible structured text, output usage and dated published-rate estimate. Provider
response IDs and reasoning are omitted. Rate limits and transient availability
failures map to the router's retryable provider errors; other failures remain
terminal. The adapter itself never retries. Any router fallback requires a new
budget reservation. `T11-META-MODEL` tests these boundaries offline, including both
models, cumulative refusal, quoted hostile tool data and joined cancellation.


## Shared persistent test budget

`MetaFileAttemptBudget` implements the dated test envelope, using the existing
`live-budget.json` and `live-budget.lock` in an explicitly supplied private local
directory. It never initializes missing state, resets attempts or refunds a
reservation. Each accepted attempt adds 1000 EUR cents; ten attempts exhaust the
10000 EUR-cent cap. All prior text and SAM attempts count, including failed,
interrupted and uncertain calls. Existing reports are preserved. New Swift
attempts remain `reserved` with a null report; this status is not a charge or a
claim of inference success.

The snapshot expires at 2026-11-02 00:00 UTC. Its recorded conversion permits a
per-attempt USD bound no larger than 11,172,000 micro-USD for the ten-EUR reserve.
Clock, qualification and input checks still apply separately in MetaLanguageModel.
Updating the dated snapshot requires reviewing pricing/FX and preserving the
ledger; removing state cannot restore spending authority.

The implementation anchors file operations to an open directory descriptor,
requires owner-only directory/file permissions and rejects symlinks and linked
regular files. A nonblocking exclusive flock uses the same lock as the Python
probe driver. Contention refuses an attempt. Strict JSON validation rejects
changed cap/FX metadata, duplicate keys and duplicate attempt IDs. The replacement
file is fully written and fsynced, atomically renamed, then the directory is
fsynced before authorization returns. An error after commit retains the uncertain
reservation and prevents dispatch. Use a local filesystem with reliable flock,
rename and fsync semantics; distributed storage is not qualified.

`T11-META-BUDGET` uses only temporary authored ledgers to test exhaustion across
new instances, Python/Swift interoperability and cross-process lock contention,
private-file checks, expiry, malformed state and cancellation. It does not touch
the real ledger, access credentials or make paid API calls. The default server
remains offline unless the explicit Meta qualification profile below is selected.


## Opt-in server qualification profile

The normal CLI now connects the real Meta adapter, HTTPS transport and shared
file budget when `SQUIDRA_PROFILE=meta-qualification` is explicitly selected.
The default `offline` profile ignores Meta credentials and makes no model calls.
This dated profile exists to qualify the selected APIs; it is not an assertion
of production retention, billing reconciliation or broad answer quality.

Required additional configuration:

- `SQUIDRA_META_CLOUD_CONSENT=1`: authorize transfer of questions and their scoped
  world/tool evidence to Meta. Standard mode and store:false do not establish ZDR.
- `SQUIDRA_META_MODEL=spark` or `wonder`: select one model; no automatic fallback.
- `SQUIDRA_META_BUDGET_DIRECTORY`: absolute path to the existing private directory
  containing the shared ledger. Its state and remaining capacity are validated
  before each attempt; `check-config` does not reserve funds or call the provider.
- Exactly one of `MODEL_API_KEY` or `MODEL_API_KEY_FILE`. The latter is an absolute
  path to an owner-only, unlinked regular 0600 file containing the raw ASCII key
  without a trailing newline. Symlinks, special files and ambiguous sources fail.
- `SQUIDRA_META_ENTITY_IDS`: one to 32 distinct canonical lowercase UUIDs separated
  by commas. These are host-authorized entities, not model-generated permissions.
  Alternatively, an enabled synthetic import profile supplies the existing
  actor/camera/scene-bound imported-entity scope. Explicit IDs may supplement it.

All existing authentication, origin and local database settings remain required.
The read host allows 2048 output tokens per call (the planner limit), reserves a conservative ten USD
per model attempt within a twenty-USD run allowance, and disables retries and
fallback. The separate shared ledger reserves ten EUR for each actual attempt
and retains the global 100 EUR cap across both language models and SAM. At least
180 seconds must remain before the pricing/FX snapshot expires at startup; each
request and reservation independently checks expiry. Missing/invalid/exhausted
budget state fails before network dispatch, without creating a new allowance.

The configuration is wired into the normal `serve` composition and existing
question routes. A simultaneous injected read host and configured Meta host is
rejected. Local host injection retains its zero-cost defaults. No new public
request fields grant cloud access or widen entity permissions. Disabling the
profile returns to offline behavior without deleting runs or budget history.

`T11-META-HOST` tests explicit activation, both model choices, consent/scope,
expiry, private-key-file rejection and actual adapter-to-file-budget execution
with a fake transport and temporary ledger. No real credential or API call is
used. End-to-end live question quality remains a separate qualification step.

## Browser import-to-question qualification (2026-11-01)

An explicitly authorized run used the normal CLI Meta profile, the real static
`/import` and `/questions` pages, isolated PostgreSQL and the authored 8×8 fixture.
The image import remained synthetic; only the public question and its scoped
world evidence were sent to Spark. No SAM world-ingestion qualification is implied.

The first attempt reserved one additional model call but the harness failed
before saving its run diagnostic. Its charge and final model outcome remain
unknown. The second attempt reserved two calls and completed the real planning,
world read, answer validation and six-event publication flow. The browser rendered
“Réponse avec preuves”. The answer cited exactly the imported source event,
retained the image hash source, location and coordinate frame, microsecond
observation/recording times, inferred basis and confidence 0.875. Runtime reached
COMPLETED and publication succeeded. The model calls reported 348 and 776 output
tokens, with a combined dated estimate of USD 0.006827.

That second harness run failed afterward at its keyboard-focus assertion because
it searched for an uppercase HTML ID while the UI deliberately lowercases proof
anchors. The selector was corrected and the uppercase-proof keyboard/logout
case was verified offline. The corrected full live harness was **not** rerun
merely to recheck that selector; no claim of a fully green live harness exit or
live screenshot is made. `fixtures/providers/meta-question-live.v1.json` preserves
this distinction and the sanitized public-data evidence. The first failed attempt
is not relabeled successful, and neither attempt's reservations are refunded.

The shared ledger now contains **six attempts / 60 EUR reserved out of 100 EUR**.
Known published-rate estimates across the initial probes and the completed
question sum to USD 0.010307, excluding the unknown charge of the first failed
question attempt. This is not invoiced spending. Four ten-EUR reservations remain.

The live harness is deliberately absent from all CI/local-gate mappings. It can
only be run explicitly with `SQUIDRA_META_QUESTION_LIVE=1` through
`Scripts/dev-db.sh test-meta-question-live`. It uses the existing repository
private key file and shared ledger, refuses fewer than two available reservations,
and never automatically resubmits a question. The normal server, not a wrapper
holding the ledger lock, reserves each actual call. Logs and temporary processes
are bounded and owned; the persistent report excludes bearer keys, database
credentials, provider response IDs and hidden reasoning.
