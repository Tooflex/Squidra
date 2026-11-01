# Historical replay demo — T08 component

Run from the repository root:

```sh
SQUIDRA_CONTAINER_ENGINE="$PWD/Scripts/colima-test-engine.py" bash Scripts/demo.sh --profile=offline-replay
```

Use the default Docker command on hosts where its loopback binding works directly.
The script builds a dedicated fixture executable, creates an owned temporary
PostgreSQL/PostGIS/pgvector database, applies the existing migrations and exports
`evidence.json` plus a timestamped `verification.json` under `.build/demo/<run>/`.
No production database, configuration, provider key or model is used. Credentials
are temporary, private and removed; the owned database is removed and absence
verified. Only the explicit offline-replay profile is accepted. Other profiles
fail before executing a model call or creating a database.

## Authored UTC scenario

| Scenario time | Authored knowledge |
| --- | --- |
| Monday 2026-10-26 09:00:00Z | Arduino on the desk, valid until Tuesday |
| Tuesday 2026-10-27 09:00:00Z | Arduino on the shelf, valid from Tuesday |
| Wednesday 2026-10-28 09:00:00Z | Correction: Monday's location was the drawer |
| Thursday 2026-10-29 09:00:00Z | Four calibrated synthetic movement samples |

The historical journal rows are **authored replay fixtures**, including their
recording timestamps, loaded only into the disposable fixture database. This
is not evidence of real observations, normal CLI ingestion, or an overridden
production recording clock. The existing production location projection reads
these persisted events and computes the actual bitemporal results. Movement
publication and notification use the production stores and their live database
recording clock. Their samples remain explicitly synthetic.

The same Monday `validAt` must return desk under Tuesday `knowledgeTime` and
drawer under Wednesday `knowledgeTime`. Tuesday's half-open boundary must still
return shelf. Exported evidence includes source event ID, source ID, basis,
confidence, observed/recorded time, requested time and timezone. Missing evidence
returns unknown; a foreign actor must be rejected.

A real production movement detector publishes one confirmed movement for the
same entity. A production watch consumes it and writes exactly one journal
notification. No email, webhook or other external notification is sent. After
the seed process exits, two fresh processes reload the persisted movement epoch,
replay its publication and consume remaining events. Both must reproduce the
identical evidence bytes, event IDs and notification ID/count without duplicates.
This qualifies fixture-process restart, not SIGKILL of the normal server or a
database restart; those recovery tests are separate.

## Completion boundary

This component runs **without an LLM** (`modelMode: none`, both fake and real
model execution false). It does not label a hardcoded answer as model output.
Fake-model orchestration, real-model integration evidence, the UI dependency
#42 and full #44 acceptance remain open. Existing Meta/SAM qualification is
separate evidence; this demo neither reuses its receipt as a new call nor spends
additional provider budget. It is not a real-perception MVP claim.
