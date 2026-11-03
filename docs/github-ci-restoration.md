# CI restoration after the local campaign

The maintainer authorized re-enabling CI at campaign end. The restored workflow
files run Bootstrap and Security for pull requests and pushes to `main`, retain
manual dispatch, and restore issue/PR metadata events. The metadata jobs check
out the default branch and treat event identifiers as data in environment
variables; they do not execute contributor code with write permissions.

Bootstrap has a 90-minute bound for cold toolchain/dependency installation plus
the full integration inventory. The measured local campaign audit uses warm
builds and cannot establish cold hosted duration. This changes the timeout, not
test selection or acceptance criteria. Windows remains unqualified.

Workflow changes alone do not enable an API-disabled workflow or protect a
branch. Finish restoration in this order:

1. Enable Bootstrap through the GitHub workflow API; verify all four workflow
   states are active.
2. Obtain actual successful hosted Bootstrap and Security runs for the final
   source, fixing failures before declaring qualification.
3. Update the existing default-branch ruleset without bypass actors. Require
   up-to-date branches and the seven exact GitHub Actions contexts below, each
   with integration ID `15368`. Preserve mandatory PRs, resolved discussions,
   protected history and the maintainer-authorized zero-review profile.
4. Run the read-only audit and record workflow/run IDs, final commit and ruleset
   results. Do not represent a local test result as hosted execution evidence.

Required contexts:

- `Swift 6.4.2 / ubuntu-24.04`
- `Swift 6.4.2 / macos-15`
- `PostgreSQL 17 / PostGIS + pgvector`
- `Dependency analysis`
- `Swift static analysis`
- `Tracked secret scan`
- `Swift lint`

```sh
python3 Scripts/check-github-rules/check.py --live --profile maintainer-ci
```

This profile intentionally preserves the explicit maintainer decision in
[github-bootstrap.md](github-bootstrap.md). It differs from the original plan's
`strict` independent-review profile. Dedicated App scope and negative/positive
merge qualification remain separate evidence; this read-only ruleset check does
not repeat or claim those tests. Repository native auto-merge stays disabled.

If a hosted runner, permissions or billing failure prevents qualification,
record the actual failure and retain the open issue. Do not remove a failing
required test or claim completion to clear the issue.
