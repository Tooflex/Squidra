# GitHub bootstrap and maintainer workflow (T10)

Repository: [Tooflex/Squidra](https://github.com/Tooflex/Squidra).
Issue: [T10 / #46](https://github.com/Tooflex/Squidra/issues/46).

## Recorded maintainer decision

On 31 October 2026, the maintainer requested `Tooflex` as code owner
without mandatory GitHub reviewers. This explicitly replaces the original
plan's requirement for an enforced approving reviewer. GitHub does not
allow authors to approve their own PRs; the only currently verified
repository administrator is `Tooflex`.

Maintainer validation and manual merging remain the workflow. Do not
claim that GitHub enforces independent human approval. CODEOWNERS records
ownership and can request review; it does not prove that review occurred.
No collaborator invitation, access grant, or separate bot identity is
part of this bootstrap.

## Initial branch

The repository was empty, with no existing commits or branches. A minimal
initial commit containing only `.gitignore` established `main`:
`a7432c262634588903451a1d790c0145be1b3b04`.

That initial push is the one-time bootstrap exception authorized by the
maintainer. Subsequent work goes through issue branches and pull
requests. T00's proposed contracts are isolated in
[PR #57](https://github.com/Tooflex/Squidra/pull/57), based on this commit.

## Active controls

The repository ruleset `main: pull requests and history protection`
(ID `26267411`) targets the default branch with no bypass actors:

- Require a pull request before changes reach `main`.
- Required approving review count: **0**, as requested by the maintainer.
- Do not require code-owner or last-push approval.
- Require resolution of review threads before merging.
- Reject forced/non-fast-forward updates and branch deletion.
- No required status checks until real CI check names are available.

Repository auto-merge is disabled. The default Actions token has read-only
permissions, and Actions cannot approve pull requests. These settings
must be checked through the GitHub API; this document alone does not
activate or prove a protection.

The maintainer can inspect effective controls with:

```bash
gh api repos/Tooflex/Squidra/rulesets
gh api repos/Tooflex/Squidra/rules/branches/main
gh api repos/Tooflex/Squidra/actions/permissions/workflow
gh repo view Tooflex/Squidra --json defaultBranchRef,mergeCommitAllowed,squashMergeAllowed
```

Inspect `allow_auto_merge` through `gh api repos/Tooflex/Squidra`.
Do not test force-push/deletion rejection destructively on `main`.

## Work branches and PRs

1. Read the issue, its dependencies, accepted ADRs, and allowed paths.
2. Branch from current `main` as `bot/<issue-number>-<slug>`; do not
   rewrite another contributor's branch.
3. Keep one bounded issue per PR. Open as Draft and use the PR template.
4. Record actual validation, unexecuted checks, risks, rollback, and
   redacted provenance. Do not fabricate tokens, cost, trace identifiers,
   or tool-manifest hashes.
5. The maintainer validates the diff and contracts, marks the PR ready,
   and merges manually. No agent auto-merge or direct push to `main`.
6. Update the issue/Project only to reflect observed completion.

For T00, ADRs remain Proposed until explicitly accepted by the maintainer.
T01 depends on that contract decision; do not represent proposed ADRs as
accepted simply because files or a Draft PR exist.

## CI and credentials

Every future workflow must declare `permissions: contents: read` by
default and elevate only permissions justified by its task. Required
checks are configured only after the workflows actually run and their
check names are verified. T01 supplies the initial build/test checks;
SQD-035 extends the security/evaluation gate later.

Never execute untrusted PR code with `pull_request_target`. Do not expose
secrets to untrusted code. Future bot execution must use a separately
verified, minimal, ephemeral GitHub App identity; no App or credential is
installed by this task.

## Verification and completion checklist

- [x] Repository and `Tooflex` administrator identity verified by API.
- [x] Minimal initial `main` commit created; T00 isolated in its own PR.
- [x] Maintainer explicitly chose ownership without mandatory reviewers.
- [x] Active ruleset and effective `main` rules verified by API.
- [x] Auto-merge disabled and Actions read-only defaults verified.
- [ ] CODEOWNERS and PR template checked and merged by the maintainer.
- [ ] Maintainer validates this bootstrap checklist.

A completed checkbox records evidence, not a promise. T10 remains open
until the maintainer validates and integrates these files. There are no
application tests at this stage. Reverting these files does not remove
server-side rules; changing rules requires an explicit administrative
operation.
