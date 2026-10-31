# Provider qualification

Observed on 2026-10-31. The server remains offline-only. No provider adapter is
activated by this document, and no live inference was performed. Public model
metadata and documentation can be verified without proving account access,
accepted weight terms, compatible execution, quality, latency or spending bounds.

## Documented contracts versus execution

| Family | Documented identifier | Documented interface | Squidra execution status |
| --- | --- | --- | --- |
| Spark | `muse-spark-1.3` | Hosted multimodal input, text output | Untested; Model API key absent |
| Wonder | `muse-wonder-1.0` | Hosted multimodal input, text output | Untested; Model API key absent |
| Glimmer | `meta-models/Muse-Glimmer-30B` | Self-hosted image/text to text | Weights not downloaded; runtime unqualified |
| SAM | `sam-3.1` | Hosted prompted image/video segmentation | Untested; key absent; wire decoder unqualified |

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
wire contract from the normalized JSON fixtures below. No SAM parser or decoder
has been qualified by these tests.
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
