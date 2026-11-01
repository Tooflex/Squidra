## Change and scope

Closes #<!-- issue number -->

<!-- Describe the problem and resulting behavior. Link accepted ADRs where applicable. -->

## Acceptance criteria and validation

- [ ] Issue acceptance criteria addressed; remaining items listed explicitly.
- [ ] Relevant positive, negative, and regression checks executed.
- [ ] Commands and actual results recorded below; skipped or unexecuted checks identified.
- [ ] Documentation and contracts updated where applicable.

<!-- For documentation-only work, report document/schema checks; do not invent application tests. -->

## Risks and rollback

<!-- Describe risks, rollback, migrations, compatibility, and permission changes; use “none” where applicable. -->

## Agent provenance

Provide a concise redacted task summary. Add exactly one structured block using
[the provenance format](../Scripts/validate-pr-metadata/README.md).
The template intentionally fails validation until actual metadata is supplied.
Use `unknown` for unmeasured model identity, tokens, or cost. Never paste secrets
or raw private prompts. Trace kind distinguishes an authoring thread from a
runtime trace; a names-only manifest is not an executable tool schema.

<!-- squidra-provenance:v1 -->
{}
<!-- /squidra-provenance -->

## Integration

- [ ] No secrets or sensitive data in code, fixtures, logs, or this description.
- [ ] Regular PR, scoped diff reviewed, actual required CI results verified on the head commit.
- [ ] Merge through the PR API after passing checks under the maintainer’s standing authorization; no protection bypass or direct main push.

<!-- Tooflex owns the code. Mandatory GitHub reviewers are intentionally disabled. -->
