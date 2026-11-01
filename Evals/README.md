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

Seven independent scorer regressions check denominators, known confusion counts,
threshold failure, baseline F1, missing/extra/duplicate cases and predictions,
non-Boolean values and ordering. The pipeline exits nonzero on build failure,
incomplete predictions, dataset mismatch or threshold failure; failed score
results remain exported for diagnosis. The issue runner checks all three explicit
completion markers and does not treat an empty suite as success.

This first gate does not complete SQD-031's broader spatiotemporal qualification.
Database-backed temporal/location queries and end-to-end question-answer quality
are not measured here. Live AI runs require an explicitly configured, qualified
model and a separately labelled dataset/run mode. Keep those results unexecuted
rather than relabelling deterministic component scores as real model performance.
