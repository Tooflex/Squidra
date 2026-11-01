# PR provenance (SQD-034 / GH-034)

Run `bash Scripts/test-issue.sh SQD-034` for offline contracts. Validate the
actual description before publishing with
`python3 Scripts/validate-pr-metadata/validate.py --body-file /path/to/body.md`.
After publication, `--pr 34` reads PR 34 from the fixed Tooflex/Squidra repository
using the existing authenticated `gh` client. It does not change the PR.

Between exactly one `<!-- squidra-provenance:v1 -->` and
`<!-- /squidra-provenance -->`, put a JSON object with these exact fields:

- `issue`: positive issue number in this repository.
- `criteria`: nonempty array of acceptance criteria, including remaining limits.
- `summary`: redacted task summary, not the raw sensitive prompt.
- `trace`: object with `kind` (`codex_thread`, `runtime_trace`, or `local_record`)
  and `id` of an actual authoring thread/runtime trace/local record. Fixture IDs
  are for tests only. A thread ID is not evidence of runtime spans.
- `tool_manifest`: object with `scope` (`used_names` or `available_names`) and
  `tools`, a sorted, unique, nonempty list of actual tool names. This deliberately
  describes names only, not executable versions, schemas, permissions or calls.
- `tool_hash`: lowercase SHA-256 of the embedded manifest encoded by Python
  `json.dumps(manifest, sort_keys=True, separators=(',', ':'), ensure_ascii=True)`
  as UTF-8. Use the validator module's `digest(manifest)` helper.
- `usage`: object with string fields `models`, `tokens`, `cost`; report measured
  values with units/scope, otherwise literally `unknown`. Do not infer billing
  from a reservation or report authoring costs as provider-test costs.
- `tests`: nonempty array of actual commands and observed results, with skipped
  or unexecuted checks stated explicitly. Text is never executed.

The validator checks structure, bounds, and the self-consistency of the hash.
It cannot authenticate a trace, prove tests ran, detect every secret, or prove
that self-reported usage and tools are truthful. Reviewers must inspect linked
records and test evidence. Existing historical PRs are not retroactively
assigned invented provenance.

`redact(text)` replaces common key assignments, bearer/GitHub tokens and PEM
private-key blocks with `[REDACTED]`. It is defense in depth, not a general
personal-data detector. The validator rejects detected credentials anywhere in
the description rather than publishing them. Prepare a minimal summary and
review it locally before submission. CLI diagnostics never echo submitted
content, parser excerpts, network response bodies, or trace identifiers.

The workflow is manual-only during the explicitly authorized CI suspension.
It checks out the trusted default branch, uses a read-only token, fetches the
PR body as data and never checks out or executes the PR head. Restore automatic
PR opened/edited/synchronize/reopened events when CI resumes; preserve the
trusted-base checkout and pass the PR number via the environment. No
`pull_request_target` execution of contributor code is permitted. Metadata
validation is not a substitute for application CI or independent review.
