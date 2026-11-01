# Qualified entity association (SQD-021)

`ContinuityEntityResolver` combines bounded appearance similarity and spatial
continuity under a configurable `AssociationPolicy`. Its score is a heuristic,
not a calibrated identity probability. Movement can preserve an entity UUID
even when a model changes its local detection IDs. Short occlusions retain
tracks until the maximum continuity gap; expired continuity creates a new
candidate rather than asserting identity.

Matches require the configured threshold and ambiguity margin. Below-threshold
results retain their candidate scores and receive a distinct entity UUID.
Two equally plausible objects, or two detections competing for one prior track,
remain ambiguous candidates. Missing appearance cannot create a confident match.
The resolver checks actor, camera, model/version, policy, ordering and capacity.

The PostgreSQL association adapter persists the bounded state with optimistic
revision checks, transactional entity creation and exact replay comparison.
Reloading through a new resolver preserves confirmed entity IDs and scores.
Corrupt/foreign state and ambiguous write acknowledgements cannot be presented
as confirmed unpersisted success. The synthetic frame ingestion composition
already connects the resolver to durable journal/projection evidence.

Acceptance evidence rechecked on 1 November 2026, at main `d62c95a`:

| Requirement | Executed evidence |
|---|---|
| Entity tracking after movement | Annotated movement fixture preserves IDs despite changed local IDs |
| Scores and configurable threshold | Below-threshold candidates retain ranked scores; policy validation rejects invalid thresholds |
| Occlusion | Short-gap recovery preserves IDs; expired gap produces distinct candidates |
| Similar objects never merged arbitrarily | Ambiguous pairs and competing detections keep separate candidates |
| Persistent identity and scope | Real PostgreSQL reload, CAS, rollback, replay, corruption and actor-isolation tests |

`SQD-021-UNIT`: 11 XCTest cases passed. `SQD-021-SQL`: those contracts plus
2 PostgreSQL XCTest cases and all 4 integration assertion markers passed.
`bash Scripts/test-issue.sh SQD-021` is an alias for that complete SQL mapping.
Use the opt-in Colima wrapper from the development guide on hosts that need it.

This qualifies SQD-021's controlled-fixture identity contract. It does not
qualify a live vision provider, physical tracking accuracy, spatial relation
publication or the full perception demo. Those remain in SQD-020/T11,
SQD-022 and the demo issues. The identity algorithm does not invent depth or
metric geometry from 2D detections.
