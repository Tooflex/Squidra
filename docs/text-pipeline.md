# Text question pipeline (T14)

Run `bash Scripts/test-issue.sh T14` for the complete local acceptance suite.
Its child suites verify planning, evidence decoding, runtime budgets, host
permissions, PostgreSQL grounding and the live HTTP composition. The full local
checks also include these suites individually.

Host context contains bounded entity IDs/labels, current explicit time, time zone,
tool schemas and a maximum query window. Labels, question text, private-memory
records and tool payloads remain data roles; they do not grant authority or change
system rules. Every proposal is decoded against a closed tool schema. Only
explicit RFC3339 query dates are accepted; unsupported relative expressions in
proposal fields are rejected rather than inferred by the host. The planner's
contract requires the model to supply explicit dates. There is no unrestricted
SQL/HTTP/shell tool or cloud fallback in the offline host.

The persisted runtime charges steps, model reservations and tool calls. A validated
proposal still passes the gateway's actor/entity/tool/scope checks before a
PostgreSQL read. Tool data is independently decoded and actor/subject-bound before
answer generation. Host validation rejects malformed responses, fabricated or
foreign citations and unsupported claims. Answers preserve source identity,
observation/recording time, confidence and uncertainty. Insufficient evidence can
produce a validated unknown answer, never fabricated evidence.

The SQL and live-server tests use controlled local model outputs as required by
T14, actual world journal/projection data, real gateway/runtime code, persisted
status and AG-UI publication. They prove the execution contract, not model quality.
The real server-composition test checks a cited database source and rejects an
entity outside the host scope. The model-free configuration advertises
`no_configured_read_host` and returns 503 for submission rather than suggesting a
model answered. Details and remaining provider activation work are in
`docs/configuration.md` and `docs/providers.md`.

Restart continuation, named-provider qualification and the user-facing demo have
separate issues. T14 does not claim their completion.
