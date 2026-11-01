# Reproducible component benchmark

Run `bash Scripts/eval.sh` or `bash Scripts/test-issue.sh SQD-031-COMPONENTS`.
Outputs are in `.build/evals/components-v1/`:

- `predictions.json`: predictions from the production Swift components.
- `results.json`: annotations, predictions, metrics with denominators and provenance.
- `baseline.json`: an always-false/no-movement baseline evaluated on exactly the same cases.
- `thresholds.json`: temporal ≥0.90, spatial ≥0.85, movement F1 ≥0.85, scoped to this dataset.

The frozen `fixtures/evals/components.v1.json` contains 30 authored synthetic cases:
10 half-open interval relations, 10 calibrated spatial predicate decisions and
10 movement sequences. Labels were authored from the documented contracts. They
are not a held-out sample of real-world images, questions or sensor observations.
The SHA-256 file guards accidental dataset edits. Annotation changes require an
explicit dataset/version/hash review; never change labels merely to pass a gate.

The separate Swift runner decodes only IDs and input fields, never expected labels.
It calls `IntervalAlgebra`, `CalibratedRelationExtractor` and
`ConfirmedMovementDetector`. The scorer then joins predictions to frozen labels
by ID. Every case must have exactly one Boolean prediction. Missing, duplicate,
extra, non-Boolean and nonfinite values fail instead of being counted as negatives.
Input ordering does not affect metrics.

Temporal and spatial accuracy are correct decisions / all decisions of that kind.
Spatial decisions ask whether one named relation is emitted; missing calibration
and ambiguous identity are authored negative/abstention cases, not proof that a
physical relation is false. Movement is binary sequence classification: did any
confirmed movement occur? It is not event localization, timing error, or counting
accuracy. F1 is `2 TP / (2 TP + FP + FN)`. Exports include TP/FP/FN/TN and precision,
recall and F1 denominators. Undefined baseline precision is null, not 1. A movement
dataset without both positive and negative cases is rejected.

Metadata records dataset and annotation versions, dataset hash, each evaluated
module source hash, lockfile hash, Git revision, dirty-tree status and Swift version.
No model is invoked: model ID/version are null, model calls are zero, and the mode
is `deterministic_components`. Source UUIDs are fresh internal identities; they do
not enter reported predictions or metrics. Repetition of these cases is not an
independent AI evaluation and cannot estimate model variance. The baseline is
exported on every run, not a fabricated or manually copied reference score.

Nine independent scorer regressions check denominators, known confusion counts,
threshold failure, baseline F1, missing/extra/duplicate cases and predictions,
non-Boolean values and ordering. The pipeline exits nonzero on build failure,
incomplete predictions, dataset mismatch or threshold failure; failed score
results remain exported for diagnosis. The issue runner checks all three explicit
completion markers and does not treat an empty suite as success.

## PostgreSQL query benchmark and complete gate

`bash Scripts/test-issue.sh SQD-031` runs both component and database profiles.
The database profile uses the same isolated PostgreSQL helper as the integration
suites, applies real migrations, seeds the immutable journal, applies the real
location projector and calls `PostgresLocationProjection.state`. It decodes input
queries only, not their annotations. No fake query service or model supplies the
predictions.

`world-queries.v1.json` freezes five source events (three locations, a late
correction and an inferred conflicting location) and twelve queries. Knowledge
times refer to actual recorded source-event boundaries, including before the first
event; valid times are fixed offsets. Thus a run does not depend on wall-clock
constants while still exercising real bitemporal queries. Temporal cases test
half-open boundaries, historical knowledge and late corrections. Spatial cases
test exact locations, absence of evidence and explicit conflict/inference flags.

A query is correct only when **all three** returned sets match: location labels,
uncertainty flags and supporting source-event indices. IDs are normalized to
fixture labels/indices without changing answer meaning. A correct place with the
wrong source is incorrect. Accuracy has separate temporal and spatial denominators;
these counts are not pooled with the component scores. The baseline always returns
no evidence. Missing or duplicate predictions, duplicate answer members and invalid
types fail. Additional scorer regressions exercise source/uncertainty mistakes.

The database exports `.build/evals/world-queries-v1/{predictions,results,baseline,
thresholds}.json`. Metadata includes the actual PostgreSQL version, migration,
source, dataset and lockfile hashes, Git state and explicit zero model calls.
No credential or temporary database port is exported. Both profiles must pass
independently: temporal accuracy >=0.90, spatial accuracy >=0.85 and the component
movement F1 >=0.85. Any failure preserves the available exported measurements and
fails the combined gate.

These are reproducible **deterministic** evaluations on authored cases. The
benchmark infrastructure and thresholds do not establish real-world AI accuracy,
end-to-end natural-language answer quality or statistical confidence on unseen
scenes. No real provider is configured in these runs; model ID/version remain
null, rather than naming an unexecuted model. Repeated AI trials belong to a
separately labelled profile with verified access and model/version provenance.
Do not count deterministic reruns as independent AI trials.
