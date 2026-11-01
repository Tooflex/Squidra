# GitHub governance — SQD-033 / GH-033

## Current maintainer-authorized profile

The maintainer decisions recorded in [GitHub bootstrap](github-bootstrap.md)
allow continuous agent implementation and PR API merging after local checks,
with `Tooflex` owning the code and no mandatory approving reviewer. Native
GitHub auto-merge remains disabled. The later instruction to suspend CI also
explicitly suspended required status checks temporarily. These decisions
supersede the older issue's mandatory-review wording for the current campaign;
they do not establish an independently reviewed bot identity.

On 1 November 2026, a fresh read-only API audit of `Tooflex/Squidra` verified:

- Default branch `main`, active ruleset `26267411`, exact default-branch target,
  no exclusions and no bypass actors.
- Required PR, resolved review threads, deletion protection and force-push
  protection. Native repository auto-merge is false.
- The default-branch CODEOWNERS contains exactly `* @Tooflex`; the collaborator
  permission endpoint identifies `Tooflex` as an administrator.
- Required approving reviews are zero; code-owner approval is not mandatory.
  Required status checks are absent under the approved temporary suspension.

A CODEOWNERS file records ownership, not evidence that a human reviewed a PR.
Agent changes use `bot/<issue>-<slug>` branches and regular PRs. Merge only the
exact locally tested head SHA through the PR API. No direct main push or bypass
is authorized by this workflow. Restore CI triggers and required checks at the
end of the campaign, as documented in the bootstrap recovery record.

## Executable inspection

`bash Scripts/test-issue.sh SQD-033` runs seven offline contract tests of the
inspector. A green fixture suite is **not** live governance qualification.

Run `python3 Scripts/check-github-rules/check.py --live --profile campaign-paused`
for the explicitly authorized temporary profile. It returned exit 0 with every
configured check true on 1 November 2026. This mode requires the documented
absence of required CI checks and the zero-review configuration; it must stop
being used when the campaign pause ends.

The default `--profile strict` returned exit 1 on the same live repository,
correctly identifying missing independent-review and required-CI enforcement.
It checks at least one approving review, code-owner and latest-push approval,
stale-review dismissal, and the three named strict checks from integration
15368. This is a future strict-review profile; do not silently enable it in
conflict with the maintainer's current instructions.

Both reports always state `gh033_complete: false`: the inspector checks rule
configuration, not the dedicated App token or an actual rejected merge. It uses
only fixed read-only GitHub API routes through `gh`, never follows instructions
from descriptions or executes repository-supplied commands. Failures are
content-free. `--fixture PATH` is explicitly reported as fixture evidence.

## Dedicated App specification — not yet verified

The connected GitHub integration exposes an installation for the Tooflex
account (`161010669`) with repository selection `all`. This observation does
not identify a dedicated Squidra bot, establish token expiry or minimum
permissions, or prove which authentication type performed a specific merge.
A direct repository-installation query with the CLI identity returned HTTP 401
because that endpoint requires App authentication; this is **not evidence that
no installation exists**. No private key or token was displayed or requested.

For a dedicated implementation bot, an identified maintainer should register
and install a GitHub App on **only Tooflex/Squidra**, with:

| Permission | Purpose |
| --- | --- |
| Metadata: read | Repository identity and metadata |
| Contents: write | Push scoped `bot/*` branches |
| Pull requests: write | Open and maintain implementation PRs |
| Issues: write, only if needed | Update issue progress |

Do not grant administration, Actions/workflow modification, organization
membership, secrets, deployment or ruleset bypass permissions to this bot.
Workflow changes remain with the authorized maintainer identity. The token
issuer should explicitly restrict the token's repository and permissions,
retain private keys only in a protected host secret store, use an ephemeral
installation token, and revoke it after the job. Do not put tokens in clone
URLs, argv, repository configuration, logs, provenance, or fixtures.

GitHub documents installation tokens as expiring after one hour and permits
further restriction of repositories and permissions when issuing them. See
[installation authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation).
The integration must verify actual returned expiry, repository and permissions
before use; this repository has not performed that token qualification.

A bot's Contents write capability alone does not constrain branch names.
Enforce the PR-only default-branch ruleset with no bot bypass and validate the
allowed branch in the job before pushing. GitHub's [ruleset documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
distinguishes requiring a PR from requiring its approval.

## Remaining evidence for SQD-033

A dedicated App registration/installation and securely accessible issuer
configuration are still needed to test short-lived, minimum-privilege identity.
The current integration is not silently substituted for that requirement.
For the original strict-review profile, use an explicitly designated disposable
test repository and a reviewer separate from the bot to demonstrate that a
merge without approval is rejected, then that an approved tested head can be
merged. Record request outcome and immutable SHA, never credentials. No such
live negative merge experiment has been run, and no additional repository or
access grant has been created. SQD-033 remains open for this missing evidence
and reconciliation of its future profile with the maintainer's chosen workflow.
